# WHY: `cce init` is the plug-and-play on-ramp and MUST be idempotent and
#      offline-first (SPEC-MCP §cce init): re-running never duplicates the
#      .mcp.json entry or the CLAUDE.md block, and it ensures an index without a
#      network. These tests prove that from a cold start.
# WHAT: Unit tests for MCP::Init.run — index ensured, .mcp.json + CLAUDE.md merged
#       and idempotent, workspace-aware, and the sync-pull branch behind a remote.

require_relative "test_helper"
require "stringio"

class McpInitTest < Minitest::Test
  include TestSupport

  def test_local_init_indexes_and_writes_config
    with_tmpdir do |dir|
      write_fixture(dir)
      res = CCE::MCP::Init.run(dir: dir, home: File.join(dir, "home"))
      assert_equal :local, res[:index][:mode]
      assert File.exist?(File.join(dir, ".cce", "index.db")), "index built"

      mcp = JSON.parse(File.read(File.join(dir, ".mcp.json")))
      assert_equal({ "command" => "cce", "args" => ["mcp", "--dir", "."] }, mcp["mcpServers"]["cce"])

      claude = File.read(File.join(dir, "CLAUDE.md"))
      assert_includes claude, CCE::MCP::Init::BEGIN_MARKER
      assert_includes claude, "context_search"
      assert_includes claude, CCE::MCP::Init::END_MARKER
    end
  end

  def test_init_is_idempotent
    with_tmpdir do |dir|
      write_fixture(dir)
      home = File.join(dir, "home")
      CCE::MCP::Init.run(dir: dir, home: home)
      CCE::MCP::Init.run(dir: dir, home: home)
      CCE::MCP::Init.run(dir: dir, home: home)

      mcp = JSON.parse(File.read(File.join(dir, ".mcp.json")))
      assert_equal 1, mcp["mcpServers"].length # no duplicate servers

      claude = File.read(File.join(dir, "CLAUDE.md"))
      assert_equal 1, claude.scan(CCE::MCP::Init::BEGIN_MARKER).length # single block
      assert_equal 1, claude.scan(CCE::MCP::Init::END_MARKER).length
    end
  end

  def test_init_preserves_existing_mcp_servers_and_claude_content
    with_tmpdir do |dir|
      write_fixture(dir)
      File.write(File.join(dir, ".mcp.json"),
                 JSON.generate("mcpServers" => { "other" => { "command" => "x" } }))
      File.write(File.join(dir, "CLAUDE.md"), "# My project\n\nExisting guidance.\n")

      CCE::MCP::Init.run(dir: dir, home: File.join(dir, "home"))

      mcp = JSON.parse(File.read(File.join(dir, ".mcp.json")))
      assert mcp["mcpServers"].key?("other"), "existing server preserved"
      assert mcp["mcpServers"].key?("cce"), "cce server added"

      claude = File.read(File.join(dir, "CLAUDE.md"))
      assert_includes claude, "Existing guidance.", "user content preserved"
      assert_includes claude, CCE::MCP::Init::BEGIN_MARKER
    end
  end

  def test_init_reuses_existing_index_without_force
    with_tmpdir do |dir|
      write_fixture(dir)
      home = File.join(dir, "home")
      CCE::MCP::Init.run(dir: dir, home: home)
      res = CCE::MCP::Init.run(dir: dir, home: home)
      assert res[:index][:reused], "second run reuses the index"
    end
  end

  def test_init_force_reindexes
    with_tmpdir do |dir|
      write_fixture(dir)
      home = File.join(dir, "home")
      CCE::MCP::Init.run(dir: dir, home: home)
      res = CCE::MCP::Init.run(dir: dir, home: home, force: true)
      refute res[:index][:reused], "force re-indexes"
    end
  end

  def test_init_rejects_unknown_agent
    with_tmpdir do |dir|
      write_fixture(dir)
      assert_raises(CCE::MCP::Error) { CCE::MCP::Init.run(dir: dir, agent: "cursor") }
    end
  end

  def test_init_workspace_detection
    with_workspace_fixture do |root|
      res = CCE::MCP::Init.run(dir: root, home: File.join(root, "home"))
      assert res[:workspace], "workspace detected"
      assert_equal :workspace, res[:index][:mode]
      mcp = JSON.parse(File.read(File.join(root, ".mcp.json")))
      assert_equal ["mcp", "--workspace"], mcp["mcpServers"]["cce"]["args"]
    end
  end

  def test_init_with_remote_pulls_ci_built_index
    with_tmpdir do |dir|
      home = File.join(dir, "home"); FileUtils.mkdir_p(home)
      source = bare_repo(File.join(dir, "source.git")) # stands in for github.com/acme/demo
      cache  = bare_repo(File.join(dir, "cache.git"))  # the sync cache remote
      # Producer (CI): repo_id derives from the shared source origin, index + push.
      producer = File.join(dir, "producer")
      init_source_repo(producer, SYNC_SAMPLE, origin: source)
      run_cli(["sync", "init", "--remote", "file://#{cache}", "--no-lfs", producer], home)
      run_cli(["sync", "push", producer], home)

      # Consumer: a checkout of the same source (same origin → same repo_id), no
      # explicit repo-id. `cce init --remote` pulls the CI-built index.
      consumer = File.join(dir, "consumer")
      init_source_repo(consumer, SYNC_SAMPLE)
      git("remote", "add", "origin", "file://#{source}", dir: consumer)

      res = CCE::MCP::Init.run(dir: consumer, remote: "file://#{cache}", home: home)
      assert_equal :sync, res[:index][:mode]
      assert File.exist?(File.join(consumer, ".cce", "index.db")), "pulled index installed"
      # auto_pull persisted so `cce mcp` warms on startup
      cfg = CCE::Sync::Config.load(consumer, home: home)
      assert cfg.auto_pull?
    end
  end

  def test_init_remote_unreachable_falls_back_to_local
    with_tmpdir do |dir|
      write_fixture(dir)
      home = File.join(dir, "home"); FileUtils.mkdir_p(home)
      res = CCE::MCP::Init.run(dir: dir, remote: "file://#{dir}/nope.git", home: home)
      assert_equal :sync_failed, res[:index][:mode]
      assert File.exist?(File.join(dir, ".cce", "index.db")), "fell back to a local index"
    end
  end

  def run_cli(argv, home)
    old = ENV["HOME"]
    ENV["HOME"] = home
    CCE::CLI.new(StringIO.new, StringIO.new).run(argv)
  ensure
    ENV["HOME"] = old
  end
end
