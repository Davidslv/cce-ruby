# WHY: The validator is the safety rail that makes adding a language safe and
#      self-diagnosing (SPEC-V2 §5). It must pass every shipped pack AND produce a
#      *helpful* diagnostic — naming pack, member, problem, and fix — for each way
#      a pack can be broken.
# WHAT: The CI test-gate over all packs, plus one deliberately-broken pack per
#       failure mode asserting the message is actionable.
# RESPONSIBILITIES: Guard the three validator layers and their diagnostics.

require_relative "test_helper"

class PackValidatorTest < Minitest::Test
  # ---- CI test-gate: every shipped pack passes all three layers --------------

  def test_all_shipped_packs_are_compatible
    packs = CCE::Packs.default_registry.all
    packs.each do |pack|
      diags = CCE::PackValidator.validate(pack, others: packs - [pack])
      assert_empty diags, "#{pack.name} should validate cleanly, got: #{diags.inspect}"
    end
  end

  # ---- Layer 2: grammar-binding lint with "did you mean" ---------------------

  # A C pack with a misspelled struct node kind.
  class MisspelledC < CCE::Packs::C
    def class_types = %w[struct_specifer union_specifier enum_specifier]
  end

  def test_misspelled_node_kind_suggests_the_real_one
    diags = CCE::PackValidator.validate(MisspelledC.new)
    joined = diags.join("\n")
    assert_includes joined, "[pack:c]"
    assert_includes joined, "class_types"
    assert_includes joined, "struct_specifer"
    assert_includes joined, "is not a node kind in tree-sitter-c"
    assert_includes joined, "Did you mean"
    assert_includes joined, "struct_specifier"
  end

  # A pack whose grammar cannot be loaded.
  class NoGrammar < CCE::Packs::C
    def grammar_name = "not_a_real_grammar_xyz"
  end

  def test_unloadable_grammar_names_the_missing_crate
    diags = CCE::PackValidator.validate(NoGrammar.new)
    assert_includes diags.join("\n"), "grammar"
    assert_includes diags.join("\n"), "failed to load"
    assert_includes diags.join("\n"), "not_a_real_grammar_xyz"
  end

  # ---- Layer 3: behavioural self-test ----------------------------------------

  # A C pack wired to enum only — its struct sample yields zero class chunks.
  class WrongClassWiring < CCE::Packs::C
    def class_types = %w[enum_specifier]
  end

  def test_wrong_wiring_reports_zero_class_chunks
    diags = CCE::PackValidator.validate(WrongClassWiring.new)
    joined = diags.join("\n")
    assert_includes joined, "[pack:c]"
    assert_includes joined, "class chunk"
    assert_includes joined, "expected at least 1"
    assert_includes joined, "enum_specifier"
  end

  # A Ruby pack whose expected imports are wrong (declares two, sample has one).
  class BadImports < CCE::Packs::Ruby
    def expected
      CCE::Packs::Expected.new(
        min_functions: 2, min_classes: 1, kinds: %w[method class], imports: %w[json extra]
      )
    end
  end

  def test_imports_mismatch_is_reported_with_both_lists
    diags = CCE::PackValidator.validate(BadImports.new)
    joined = diags.join("\n")
    assert_includes joined, "imports mismatch"
    assert_includes joined, %(["json"])
    assert_includes joined, %(["json", "extra"])
  end

  # ---- Layer 1: structural lint ----------------------------------------------

  class BadExtension < CCE::Packs::C
    def extensions = ["c"] # missing leading dot
  end

  def test_bad_extension_format_is_flagged
    diags = CCE::PackValidator.validate(BadExtension.new)
    assert_includes diags.join("\n"), "leading-dot string"
  end

  class ClashingC < CCE::Packs::C
    def name = "c-clash"
    def extensions = [".rb"]
  end

  def test_duplicate_extension_across_packs_is_flagged
    ruby = CCE::Packs::Ruby.new
    diags = CCE::PackValidator.validate(ClashingC.new, others: [ruby])
    joined = diags.join("\n")
    assert_includes joined, "[pack:c-clash]"
    assert_includes joined, %(".rb" already claimed by pack "ruby")
  end

  class IncompletePack
    def name = "incomplete"
    def extensions = [".zz"]
  end

  def test_incomplete_interface_is_flagged
    diags = CCE::PackValidator.validate(IncompletePack.new)
    joined = diags.join("\n")
    assert_includes joined, "[pack:incomplete]"
    assert_includes joined, "does not implement the pack interface"
    assert_includes joined, "extract_imports"
  end

  # ---- compatible? convenience -----------------------------------------------

  def test_compatible_predicate
    assert CCE::PackValidator.compatible?(CCE::Packs::Ruby.new)
    refute CCE::PackValidator.compatible?(MisspelledC.new)
  end

  # ---- fail-fast startup (Layer 1 only) --------------------------------------

  def test_fail_fast_raises_on_unloadable_grammar
    reg = CCE::PackRegistry.new
    reg.register(NoGrammar.new)
    err = assert_raises(RuntimeError) { CCE::Packs.fail_fast!(reg) }
    assert_includes err.message, "failed to load"
  end

  def test_fail_fast_passes_for_the_default_registry
    assert_same_registry = CCE::Packs.fail_fast!(CCE::Packs.default_registry)
    assert_equal 6, assert_same_registry.all.length
  end
end
