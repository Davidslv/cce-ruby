# WHY: The Context concentrates the store-resolution, read-only, offline, and
#      soft-sync-dependency policy (SPEC-MCP §2, §CCE MCP × CCE Sync). Its edges —
#      missing index, workspace federation + package scoping, and the best-effort
#      auto-pull behind a local bare git remote — must be proven hermetically.
# WHAT: Direct unit tests of Context.search / index_status / warm_up! for the
#       single-repo, workspace, missing-index, and sync-aware paths.

require_relative "test_helper"
require "stringio"

class McpContextTest < Minitest::Test
  include TestSupport

  def det_context(dir:, home: nil, **kw)
    CCE::MCP::Context.new(
      dir: dir, home: home || File.join(dir, "home"),
      clock: CCE::Metrics::FixedClock.new("2026-07-05T10:00:00Z"),
      id_source: CCE::Metrics::SequenceIdSource.new(%w[qid1 qid2 qid3 qid4]), **kw
    )
  end

  def test_missing_index_search_is_friendly_not_crash
    with_tmpdir do |dir|
      ctx = det_context(dir: dir)
      refute ctx.indexed?
      out = ctx.search("anything", top_k: 8, graph_enabled: true)
      assert_equal false, out[:indexed]
      assert_empty out[:results]
    end
  end

  def test_missing_index_status_reports_not_indexed
    with_tmpdir do |dir|
      st = det_context(dir: dir).index_status
      assert_equal false, st[:indexed]
      assert_equal "local", st[:sync][:source]
    end
  end

  def test_single_repo_search_records_metrics_and_query_id
    with_tmpdir do |dir|
      write_fixture(dir)
      CCE::Indexer.index(dir, store_path: File.join(dir, ".cce", "index.db"), embedder: "hash")
      out = det_context(dir: dir).search("hash password", top_k: 5, graph_enabled: true)
      assert out[:indexed]
      assert_equal "qid1", out[:query_id]
      refute_empty out[:results]
      log = File.join(dir, ".cce", "metrics.jsonl")
      ev = File.readlines(log).map { |l| JSON.parse(l) }.find { |e| e["event"] == "search" }
      assert_equal 5, ev["top_k"]
      # v2.4: the MCP/agent path tags its searches so the dashboard can split
      # agent-vs-human usage.
      assert_equal "mcp", ev["source"]
    end
  end

  def test_index_status_counts_and_breakdown
    with_tmpdir do |dir|
      write_fixture(dir)
      CCE::Indexer.index(dir, store_path: File.join(dir, ".cce", "index.db"), embedder: "hash")
      st = det_context(dir: dir).index_status
      assert st[:indexed]
      assert_operator st[:chunk_count], :>, 0
      assert_operator st[:file_count], :>, 0
      assert st[:by_language].key?("python")
      assert_equal "hash", st[:embedder]
    end
  end

  def test_explicit_store_path_wins
    with_tmpdir do |dir|
      store = File.join(dir, "custom", "idx.db")
      write_fixture(dir)
      CCE::Indexer.index(dir, store_path: store, embedder: "hash")
      ctx = CCE::MCP::Context.new(dir: dir, store: store, home: File.join(dir, "home"))
      assert ctx.indexed?
    end
  end

  # ---- workspace -----------------------------------------------------------

  def test_workspace_search_with_package_scoping
    with_workspace_fixture do |root|
      CCE::Workspace::Manifest.detect(root).write(root)
      CCE::Workspace::Indexer.index(root, embedder: "hash", record_metrics: false)
      ctx = det_context(dir: root, workspace: true)
      assert ctx.indexed?
      out = ctx.search("charge", top_k: 8, graph_enabled: true, package: "app")
      assert out[:indexed]
      # every scoped result belongs to the requested member
      out[:results].each { |r| assert_equal "app", r[:package] } unless out[:results].empty?
      log = File.join(root, ".cce", "metrics.jsonl")
      assert File.exist?(log)
    end
  end

  def test_workspace_unknown_package_raises
    with_workspace_fixture do |root|
      CCE::Workspace::Manifest.detect(root).write(root)
      CCE::Workspace::Indexer.index(root, embedder: "hash", record_metrics: false)
      ctx = det_context(dir: root, workspace: true)
      assert_raises(CCE::Workspace::Error) do
        ctx.search("x", top_k: 8, graph_enabled: true, package: "nope")
      end
    end
  end

  def test_workspace_status_reports_members
    with_workspace_fixture do |root|
      CCE::Workspace::Manifest.detect(root).write(root)
      CCE::Workspace::Indexer.index(root, embedder: "hash", record_metrics: false)
      st = det_context(dir: root, workspace: true).index_status
      assert st[:workspace]
      assert st[:indexed]
      refute_empty st[:members]
    end
  end

  # ---- sync soft dependency ------------------------------------------------

  def test_warm_up_noop_without_sync
    with_tmpdir do |dir|
      assert_equal :skipped, det_context(dir: dir).warm_up!
    end
  end

  def test_warm_up_auto_pulls_latest_from_bare_remote
    with_tmpdir do |dir|
      home = File.join(dir, "home"); FileUtils.mkdir_p(home)
      cache = bare_repo(File.join(dir, "cache.git"))
      # Producer: index + push a cache for the source repo's HEAD.
      producer = File.join(dir, "producer")
      sha = init_source_repo(producer, SYNC_SAMPLE, origin: cache)
      run_sync(["sync", "init", "--remote", "file://#{cache}", "--no-lfs",
                "--repo-id", "demo__repo", producer], home)
      run_sync(["sync", "push", producer], home)

      # Consumer: a fresh checkout of the same source (its own commit, no origin
      # push), sync configured with auto_pull on. warm-up pulls --latest.
      consumer = File.join(dir, "consumer")
      init_source_repo(consumer, SYNC_SAMPLE)
      CCE::Sync::Config.write_project(consumer, remote: "file://#{cache}", lfs: false,
                                       repo_id: "demo__repo", auto_pull: true)

      ctx = det_context(dir: consumer, home: home)
      refute ctx.indexed?, "consumer starts with no local index"
      assert_equal :pulled, ctx.warm_up!
      assert ctx.indexed?, "warm-up pulled the cached index"

      st = ctx.index_status
      assert_equal "sync-pull", st[:sync][:source]
      assert_equal sha, st[:sync][:sha]
      assert_equal false, st[:sync][:behind_remote]
    end
  end

  def test_warm_up_offline_safe_when_remote_absent
    with_tmpdir do |dir|
      home = File.join(dir, "home"); FileUtils.mkdir_p(home)
      # Point at a non-existent remote; auto_pull on. Must NOT raise.
      CCE::Sync::Config.write_project(dir, remote: "file://#{dir}/nope.git", lfs: false,
                                       repo_id: "demo__repo", auto_pull: true)
      assert_equal :offline, det_context(dir: dir, home: home).warm_up!
    end
  end

  def run_sync(argv, home)
    old = ENV["HOME"]
    ENV["HOME"] = home
    CCE::CLI.new(StringIO.new, StringIO.new).run(argv)
  ensure
    ENV["HOME"] = old
  end
end
