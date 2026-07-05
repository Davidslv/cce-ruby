# WHY: Each pack's `sample`/`expected` is the hand-derived pin on its chunking
#      and import extraction (SPEC-V2 §6), and the sample must be byte-identical
#      to the shipped conformance fixture or the cross-language gate is meaningless.
# WHAT: Runs every shipped pack over its own sample and checks counts, kinds and
#       imports; asserts sample == fixture bytes; checks extension/grammar shape.
# RESPONSIBILITIES: Guard the six packs' behaviour, samples, and interface shape.

require_relative "test_helper"

class PacksTest < Minitest::Test
  SAMPLES_DIR = File.expand_path("fixture/samples", __dir__)

  def registry = CCE::Packs.default_registry

  def chunk(pack, source)
    reg = CCE::PackRegistry.new
    reg.register(pack)
    CCE::Chunker.chunk_file(source, "sample#{pack.extensions.first}", registry: reg)
  end

  def test_every_pack_meets_its_expected_over_its_sample
    registry.all.each do |pack|
      chunks = chunk(pack, pack.sample)
      fns = chunks.count { |c| c.chunk_type == "function" }
      classes = chunks.count { |c| c.chunk_type == "class" }
      kinds = chunks.map(&:kind).uniq
      exp = pack.expected

      assert_operator fns, :>=, exp.min_functions, "#{pack.name}: function count"
      assert_operator classes, :>=, exp.min_classes, "#{pack.name}: class count"
      exp.kinds.each { |k| assert_includes kinds, k, "#{pack.name}: kind #{k}" }
    end
  end

  def test_every_pack_extracts_its_expected_imports_exactly
    registry.all.each do |pack|
      reg = CCE::PackRegistry.new
      reg.register(pack)
      imports = CCE::Chunker.extract_imports(pack.sample, "sample#{pack.extensions.first}", registry: reg)
      assert_equal pack.expected.imports, imports, "#{pack.name}: imports"
    end
  end

  def test_pack_sample_matches_shipped_fixture_byte_for_byte
    {
      "python" => "python.py", "javascript" => "javascript.js", "ruby" => "ruby.rb",
      "rust" => "rust.rs", "typescript" => "typescript.ts", "c" => "c.c"
    }.each do |name, file|
      pack = registry.all.find { |p| p.name == name }
      fixture = File.binread(File.join(SAMPLES_DIR, file))
      assert_equal fixture, pack.sample.b, "#{name}: sample must equal #{file} byte-for-byte"
    end
  end

  def test_extensions_are_lowercase_leading_dot_and_unique_across_packs
    seen = {}
    registry.all.each do |pack|
      pack.extensions.each do |ext|
        assert_match(/\A\.[a-z0-9]+\z/, ext, "#{pack.name}: #{ext}")
        refute seen.key?(ext), "extension #{ext} claimed twice"
        seen[ext] = pack.name
      end
    end
  end

  def test_every_pack_grammar_loads
    registry.all.each do |pack|
      refute_nil pack.grammar, "#{pack.name}: grammar should load"
    end
  end

  def test_ruby_require_takes_last_path_segment_stem
    pack = registry.all.find { |p| p.name == "ruby" }
    reg = CCE::PackRegistry.new
    reg.register(pack)
    src = %(require "a/b"\nrequire_relative "./sub/thing"\nrequire "json"\n)
    imports = CCE::Chunker.extract_imports(src, "x.rb", registry: reg)
    assert_equal %w[b thing json], imports
  end

  def test_rust_use_takes_first_path_segment_and_dedupes
    pack = registry.all.find { |p| p.name == "rust" }
    reg = CCE::PackRegistry.new
    reg.register(pack)
    src = "use std::collections::HashMap;\nuse std::fmt;\nuse crate::store::Index;\n"
    imports = CCE::Chunker.extract_imports(src, "x.rs", registry: reg)
    assert_equal %w[std crate], imports
  end

  def test_c_include_handles_system_and_quoted
    pack = registry.all.find { |p| p.name == "c" }
    reg = CCE::PackRegistry.new
    reg.register(pack)
    src = %(#include <stdlib.h>\n#include "store.h"\n#include <sys/types.h>\n)
    imports = CCE::Chunker.extract_imports(src, "x.c", registry: reg)
    assert_equal %w[stdlib store types], imports
  end

  class BareBase < CCE::Packs::Base; end

  def test_base_pack_interface_is_abstract
    bare = BareBase.new
    %i[name extensions grammar_name function_types class_types extract_imports sample expected].each do |m|
      assert_raises(NotImplementedError, "#{m} should be abstract") do
        m == :extract_imports ? bare.public_send(m, nil, "") : bare.public_send(m)
      end
    end
    assert_equal [], bare.import_node_types
    assert_match(/pack:/, CCE::Packs::Python.new.to_s)
  end

  def test_unknown_grammar_returns_nil
    assert_nil CCE::Grammars.language("definitely_not_a_grammar")
  end

  def test_typescript_scoped_package_kept_whole
    pack = registry.all.find { |p| p.name == "typescript" }
    reg = CCE::PackRegistry.new
    reg.register(pack)
    src = %(import x from "@scope/pkg";\nimport y from "./local";\n)
    imports = CCE::Chunker.extract_imports(src, "x.ts", registry: reg)
    assert_equal ["@scope/pkg", "local"], imports
  end
end
