# WHY: The CLI is the delivered product surface; it must index/search across
#      separate process runs, emit JSON, and fail gracefully (SPEC §9, §13).
# WHAT: Pins CLI happy paths (index -> stats -> search, in-process and via the
#       real executable in a fresh process), JSON output, and invalid input.
# RESPONSIBILITIES: Guard command dispatch, exit codes, and persistence across
#       processes.

require_relative "test_helper"
require "json"
require "open3"

class CLITest < Minitest::Test
  include TestSupport

  def capture(argv)
    out = StringIO.new
    err = StringIO.new
    code = CCE::CLI.run(argv, out: out, err: err)
    [code, out.string, err.string]
  end

  def test_index_then_stats_then_search_in_process
    with_tmpdir do |dir|
      write_fixture(dir)
      code, out, = capture(["index", dir])
      assert_equal 0, code
      assert_match(/Indexed 3 files/, out)

      code, out, = capture(["stats", "--dir", dir])
      assert_equal 0, code
      assert_match(/Chunks:\s+7/, out)

      code, out, = capture(["search", "hash", "password", "--dir", dir, "--top-k", "5", "--no-graph"])
      assert_equal 0, code
      assert_match(/auth\.py/, out)
    end
  end

  def test_search_json_output
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      code, out, = capture(["search", "process payment", "--dir", dir, "--json", "--no-graph"])
      assert_equal 0, code
      parsed = JSON.parse(out)
      # v1.1: --json is an object carrying query_id + results (DASHBOARD-SPEC §5).
      assert parsed.is_a?(Hash)
      results = parsed["results"]
      assert results.is_a?(Array)
      assert_match(/\A\d+\.\d{6}\z/, results.first["score"])
      assert_equal 1, results.first["rank"]
    end
  end

  def test_invalid_search_without_store_or_dir
    code, _out, err = capture(["search", "anything"])
    assert_equal 2, code
    assert_match(/--dir or --store/, err)
  end

  def test_packs_lists_the_six_packs
    code, out, = capture(["packs"])
    assert_equal 0, code
    assert_match(/Registered language packs \(6\):/, out)
    %w[python javascript ruby rust typescript c].each { |n| assert_match(/\b#{n}\b/, out) }
    assert_match(/grammar=rust/, out)
  end

  def test_packs_validate_passes_for_all_shipped_packs
    code, out, err = capture(["packs", "--validate"])
    assert_equal 0, code
    assert_match(/Validating 6 packs/, out)
    assert_match(/All 6 packs valid\./, out)
    assert_equal "", err
    refute_match(/FAIL/, out)
  end

  def test_search_json_and_stats_carry_kind
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])

      code, out, = capture(["search", "hash password", "--dir", dir, "--json", "--no-graph"])
      assert_equal 0, code
      results = JSON.parse(out)["results"]
      assert results.first.key?("kind")
      refute_empty results.first["kind"].to_s

      code, out, = capture(["stats", "--dir", dir])
      assert_equal 0, code
      assert_match(/Kinds:\s+.*function_definition/, out)
    end
  end

  # A deliberately broken pack: its struct node kind is misspelled.
  class BrokenC < CCE::Packs::C
    def name = "broken-c"
    def extensions = [".brokenc"]
    def class_types = %w[struct_specifer]
  end

  def test_packs_validate_prints_helpful_diagnostic_and_exits_nonzero
    reg = CCE::PackRegistry.new
    reg.register(BrokenC.new)
    CCE.registry = reg
    begin
      code, out, err = capture(["packs", "--validate"])
      assert_equal 1, code
      assert_match(/FAIL\s+broken-c/, out)
      assert_match(/struct_specifer/, out)
      assert_match(/Did you mean.*struct_specifier/, out)
      assert_match(/failed validation/, err)
    ensure
      CCE.reset_registry!
    end
  end

  def test_search_human_output_shows_kind
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      code, out, = capture(["search", "hash password", "--dir", dir, "--no-graph"])
      assert_equal 0, code
      assert_match(%r{\(function/function_definition\)}, out)
    end
  end

  def test_index_missing_dir
    code, _out, err = capture(["index", "/nonexistent/path/xyz"])
    assert_equal 2, code
    assert_match(/no such directory/, err)
  end

  def test_search_missing_store_is_friendly_error
    with_tmpdir do |dir|
      code, _out, err = capture(["search", "foo", "--store", File.join(dir, "missing.db")])
      assert_equal 1, code
      assert_match(/no index found/, err)
    end
  end

  def test_unknown_command
    code, _out, err = capture(["frobnicate"])
    assert_equal 2, code
    assert_match(/unknown command/, err)
  end

  def test_empty_query_returns_no_results
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      code, out, = capture(["search", "   ", "--dir", dir])
      assert_equal 2, code # empty query is a usage error
    end
  end

  # Fresh-process guarantee: index in one process, search in another via bin/cce.
  def test_fresh_process_index_then_search
    with_tmpdir do |dir|
      write_fixture(dir)
      bin = File.expand_path("../bin/cce", __dir__)
      env = { "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__) }

      o1, s1 = Open3.capture2e(env, "bundle", "exec", bin, "index", dir)
      assert s1.success?, o1

      o2, s2 = Open3.capture2e(env, "bundle", "exec", bin, "search", "hash password",
                               "--dir", dir, "--no-graph", "--json")
      assert s2.success?, o2
      parsed = JSON.parse(o2.lines.last)
      assert_equal "auth.py", parsed["results"].first["file_path"]
    end
  end
end
