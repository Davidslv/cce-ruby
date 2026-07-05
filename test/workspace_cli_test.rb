# WHY: The workspace commands are the delivered surface (SPEC-V2.2 §9); they must
#      init/list/index/search/stats end-to-end, tag results by package, scope with
#      --package (erroring on unknown), and leave single-repo behaviour untouched.
# WHAT: In-process CLI tests for the `workspace` command and the `--workspace` flag.

require_relative "test_helper"
require "json"

class WorkspaceCLITest < Minitest::Test
  include TestSupport

  def capture(argv)
    out = StringIO.new
    err = StringIO.new
    code = CCE::CLI.run(argv, out: out, err: err)
    [code, out.string, err.string]
  end

  def test_workspace_init_then_list
    with_workspace_fixture do |root|
      code, out, = capture(["workspace", "init", root])
      assert_equal 0, code
      assert_match(/Wrote .*workspace\.yml/, out)
      assert_match(/app \[rails-app\]/, out)
      assert_match(/billing \[ruby-engine\]/, out)
      assert File.exist?(CCE::Workspace::Manifest.path_for(root))

      code, out, = capture(["workspace", "list", root])
      assert_equal 0, code
      assert_match(/3 members/, out)
      assert_match(/app -> billing \(gemfile\)/, out)
    end
  end

  def test_workspace_init_refuses_overwrite_without_force
    with_workspace_fixture do |root|
      capture(["workspace", "init", root])
      code, _out, err = capture(["workspace", "init", root])
      assert_equal 1, code
      assert_match(/already exists/, err)
      code, = capture(["workspace", "init", root, "--force"])
      assert_equal 0, code
    end
  end

  def test_workspace_unknown_subcommand
    code, _out, err = capture(["workspace", "bogus"])
    assert_equal 2, code
    assert_match(/init \| list/, err)
  end

  def test_index_workspace_then_stats
    with_workspace_fixture do |root|
      capture(["workspace", "init", root])
      code, out, = capture(["index", "--workspace", root])
      assert_equal 0, code
      assert_match(/3 members/, out)
      assert_match(/1 cross-member edges/, out)

      code, out, = capture(["stats", "--workspace", root])
      assert_equal 0, code
      assert_match(/app \[rails-app\]/, out)
      assert_match(/app -> billing \(gemfile\)/, out)
    end
  end

  def test_search_workspace_human_and_json
    with_workspace_fixture do |root|
      capture(["workspace", "init", root])
      capture(["index", "--workspace", root])

      code, out, = capture(["search", "charge", "--workspace", root, "--no-graph"])
      assert_equal 0, code
      assert_match(/·/, out)
      assert_match(/(app|billing) ·/, out)

      code, out, = capture(["search", "charge", "--workspace", root, "--json", "--no-graph"])
      assert_equal 0, code
      parsed = JSON.parse(out)
      assert parsed["query_id"].is_a?(String)
      first = parsed["results"].first
      assert %w[app billing web].include?(first["package"])
      assert_match(/\A\d+\.\d{6}\z/, first["score"])
    end
  end

  def test_search_workspace_package_scoping_and_unknown
    with_workspace_fixture do |root|
      capture(["workspace", "init", root])
      capture(["index", "--workspace", root])

      code, out, = capture(["search", "charge amount", "--workspace", root, "--package", "billing", "--json", "--no-graph"])
      assert_equal 0, code
      packages = JSON.parse(out)["results"].map { |r| r["package"] }.uniq
      assert_equal ["billing"], packages

      code, _out, err = capture(["search", "charge", "--workspace", root, "--package", "nope"])
      assert_equal 1, code
      assert_match(/unknown package/, err)
    end
  end

  def test_search_workspace_rejects_empty_query
    with_workspace_fixture do |root|
      capture(["workspace", "init", root])
      code, _out, err = capture(["search", "", "--workspace", root])
      assert_equal 2, code
      assert_match(/requires a <query>/, err)
    end
  end

  def test_workspace_commands_default_to_current_dir
    with_workspace_fixture do |root|
      Dir.chdir(root) do
        assert_equal 0, capture(["workspace", "init"]).first
        assert_equal 0, capture(["index", "--workspace"]).first
        code, out, = capture(["search", "charge", "--workspace"])
        assert_equal 0, code
        assert_match(/·/, out)
        assert_equal 0, capture(["stats", "--workspace"]).first
        assert_equal 0, capture(["workspace", "list"]).first
      end
    end
  end

  def test_search_workspace_graph_hop_appears_in_output
    with_workspace_fixture do |root|
      capture(["workspace", "init", root])
      capture(["index", "--workspace", root])
      # "process" matches app only; the graph pulls billing chunks in.
      _code, without, = capture(["search", "process", "--workspace", root, "--top-k", "1", "--no-graph", "--json"])
      _code, with, = capture(["search", "process", "--workspace", root, "--top-k", "1", "--json"])
      wo = JSON.parse(without)["results"].map { |r| r["package"] }
      w = JSON.parse(with)["results"].map { |r| r["package"] }
      refute_includes wo, "billing"
      assert_includes w, "billing"
    end
  end

  def test_stats_workspace_reports_unindexed
    with_workspace_fixture do |root|
      capture(["workspace", "init", root])
      code, out, = capture(["stats", "--workspace", root])
      assert_equal 0, code
      assert_match(/\(not indexed\)/, out)
      assert_match(/Totals: 0 files, 0 chunks/, out)
    end
  end

  def test_help_mentions_workspace
    _code, out, = capture(["help"])
    assert_match(/workspace init/, out)
    assert_match(/--workspace/, out)
  end

  def test_single_repo_search_unchanged
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      code, out, = capture(["search", "hash password", "--dir", dir, "--no-graph"])
      assert_equal 0, code
      assert_match(/auth\.py/, out)
    end
  end
end
