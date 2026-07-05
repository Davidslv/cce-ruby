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
      assert parsed.is_a?(Array)
      assert_match(/\A\d+\.\d{6}\z/, parsed.first["score"])
      assert_equal 1, parsed.first["rank"]
    end
  end

  def test_invalid_search_without_store_or_dir
    code, _out, err = capture(["search", "anything"])
    assert_equal 2, code
    assert_match(/--dir or --store/, err)
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
      assert_equal "auth.py", parsed.first["file_path"]
    end
  end
end
