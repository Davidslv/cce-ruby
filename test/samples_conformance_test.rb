# WHY: The seven sample files are both the pack self-tests and the cross-language
#      conformance corpus; the v2 conformance output must carry `kind` and the
#      fixed module-fallback line count so the two implementations diff to
#      byte-identical chunk arrays (SPEC-V2 §4, §6, §7).
# WHAT: Runs conformance over test/fixture/samples and pins the v2 chunk shape,
#       the fallback chunk, per-language kinds, and determinism.
# RESPONSIBILITIES: Guard the v2 conformance manifest over the sample corpus.

require_relative "test_helper"
require "json"

class SamplesConformanceTest < Minitest::Test
  SAMPLES_DIR = File.expand_path("fixture/samples", __dir__)

  def run_conf = CCE::Conformance.run(SAMPLES_DIR)

  def test_indexes_all_seven_sample_files
    files = run_conf[:chunks].map { |c| c[:file_path] }.uniq
    assert_equal %w[c.c javascript.js notes.md python.py ruby.rb rust.rs typescript.ts], files.sort
  end

  def test_every_chunk_carries_a_kind
    run_conf[:chunks].each do |c|
      refute_nil c[:kind]
      refute_empty c[:kind].to_s
    end
  end

  def test_chunk_manifest_v2_field_order
    c = run_conf[:chunks].first
    assert_equal %i[file_path start_line end_line chunk_type kind chunk_id token_count], c.keys
  end

  def test_module_fallback_line_count_fix
    md = run_conf[:chunks].find { |c| c[:file_path] == "notes.md" }
    assert_equal "module", md[:chunk_type]
    assert_equal "module", md[:kind]
    assert_equal 1, md[:start_line]
    assert_equal 3, md[:end_line] # two "\n" bytes + 1 (SPEC-V2 §4)
  end

  def test_notes_md_is_the_only_fallback_chunk
    modules = run_conf[:chunks].select { |c| c[:chunk_type] == "module" }
    assert_equal ["notes.md"], modules.map { |c| c[:file_path] }
  end

  def test_expected_kinds_per_language
    by_file = run_conf[:chunks].group_by { |c| c[:file_path] }
    kinds = ->(f) { by_file[f].map { |c| c[:kind] }.uniq.sort }
    assert_includes kinds.call("c.c"), "struct_specifier"
    assert_includes kinds.call("c.c"), "function_definition"
    assert_includes kinds.call("ruby.rb"), "method"
    assert_includes kinds.call("ruby.rb"), "class"
    assert_includes kinds.call("rust.rs"), "impl_item"
    assert_includes kinds.call("rust.rs"), "struct_item"
    assert_includes kinds.call("typescript.ts"), "interface_declaration"
  end

  def test_chunks_sorted_canonically
    keys = run_conf[:chunks].map { |c| [c[:file_path], c[:start_line], c[:chunk_id]] }
    assert_equal keys.sort, keys
  end

  def test_json_is_deterministic_and_carries_kind
    a = CCE::Conformance.to_json(SAMPLES_DIR)
    b = CCE::Conformance.to_json(SAMPLES_DIR)
    assert_equal a, b
    parsed = JSON.parse(a)
    assert parsed["chunks"].all? { |c| c.key?("kind") }
    assert_equal "2.0", parsed["spec_version"]
  end

  # The committed conformance.json is the cross-language equivalence gate. Secret
  # protection (SPEC-V2.1) must not perturb it — the samples carry no secrets and
  # no sensitive filenames, so this output stays byte-identical.
  def test_committed_conformance_json_is_byte_identical
    committed = File.read(File.expand_path("../conformance.json", __dir__))
    assert_equal committed, CCE::Conformance.to_json(SAMPLES_DIR)
  end

  def test_conformance_reflects_indexed_store_with_kind
    with_tmpdir do |dir|
      store = File.join(dir, "index.db")
      CCE::Indexer.index(SAMPLES_DIR, store_path: store, embedder: "hash")
      s = CCE::Store.open(store)
      begin
        kinds = s.chunks.map(&:kind)
        assert_includes kinds, "function_item"
        assert_includes kinds, "module"
        assert_equal %w[std], s.file_imports["rust.rs"]
        assert_equal %w[json], s.file_imports["ruby.rb"]
      ensure
        s.close
      end
    end
  end

  include TestSupport
end
