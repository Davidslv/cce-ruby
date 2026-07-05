# WHY: The registry is the single indirection that lets the core stay
#      language-blind (SPEC-V2 §1.1). Its resolution and its refusal to let two
#      packs claim one extension are load-bearing invariants.
# WHAT: Pins register/pack_for/all and duplicate-extension rejection.
# RESPONSIBILITIES: Guard registry resolution and the one-extension-one-pack rule.

require_relative "test_helper"

class PackRegistryTest < Minitest::Test
  # A minimal fake pack: only the members the registry touches.
  FakePack = Struct.new(:name, :extensions)

  def test_pack_for_resolves_by_lowercased_extension
    reg = CCE::PackRegistry.new
    rb = FakePack.new("ruby", [".rb"])
    reg.register(rb)
    assert_same rb, reg.pack_for("lib/foo.rb")
    assert_same rb, reg.pack_for("LIB/FOO.RB")
    assert_nil reg.pack_for("README.md")
  end

  def test_all_returns_registration_order
    reg = CCE::PackRegistry.new
    a = FakePack.new("a", [".a"])
    b = FakePack.new("b", [".b"])
    reg.register(a)
    reg.register(b)
    assert_equal %w[a b], reg.all.map(&:name)
  end

  def test_register_rejects_duplicate_extension_with_helpful_message
    reg = CCE::PackRegistry.new
    reg.register(FakePack.new("ruby", [".rb"]))
    err = assert_raises(CCE::PackRegistry::DuplicateExtension) do
      reg.register(FakePack.new("ruby-legacy", [".rb"]))
    end
    assert_includes err.message, "pack:ruby-legacy"
    assert_includes err.message, %(".rb" already claimed by pack "ruby")
    assert_includes err.message, "exactly one pack"
  end

  def test_register_is_atomic_on_conflict
    reg = CCE::PackRegistry.new
    reg.register(FakePack.new("ruby", [".rb"]))
    assert_raises(CCE::PackRegistry::DuplicateExtension) do
      reg.register(FakePack.new("multi", [".new", ".rb"]))
    end
    # The un-conflicting extension must NOT have been half-registered.
    assert_nil reg.pack_for("x.new")
    assert_equal 1, reg.all.length
  end

  def test_default_registry_has_the_six_packs
    reg = CCE::Packs.default_registry
    assert_equal %w[python javascript ruby rust typescript c], reg.all.map(&:name)
  end

  def test_default_registry_resolves_each_language
    reg = CCE::Packs.default_registry
    {
      "a.py" => "python", "a.js" => "javascript", "a.mjs" => "javascript",
      "a.rb" => "ruby", "a.rs" => "rust", "a.ts" => "typescript",
      "a.tsx" => "typescript", "a.c" => "c", "a.h" => "c"
    }.each do |path, lang|
      assert_equal lang, reg.pack_for(path).name, path
    end
    assert_nil reg.pack_for("a.md")
  end
end
