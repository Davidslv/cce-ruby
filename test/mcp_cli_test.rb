# WHY: `cce mcp` and `cce init` are how a user drives MCP from the shell; the CLI
#      must dispatch them, print friendly output, and (for `mcp`) speak JSON-RPC
#      over the injected stdin/stdout (SPEC-MCP §The server, §cce init). These are
#      end-to-end tests through CCE::CLI, still hermetic (StringIO, no editor/net).
# WHAT: CLI dispatch tests for `cce mcp` (piped JSON-RPC) and `cce init`.

require_relative "test_helper"
require "stringio"

class McpCliTest < Minitest::Test
  include TestSupport

  def run_cli(argv, inp: StringIO.new, home: Dir.mktmpdir)
    out = StringIO.new
    err = StringIO.new
    old = ENV["HOME"]
    ENV["HOME"] = home
    code = CCE::CLI.new(out, err, inp).run(argv)
    [code, out.string, err.string]
  ensure
    ENV["HOME"] = old
  end

  def test_help_lists_mcp_and_init
    _code, out, = run_cli(["help"])
    assert_match(/cce init /, out)
    assert_match(/cce mcp/, out)
    assert_match(/Use it with Claude Code \(MCP/, out)
  end

  def test_mcp_serves_over_stdio_until_eof
    with_tmpdir do |dir|
      write_fixture(dir)
      CCE::Indexer.index(dir, store_path: File.join(dir, ".cce", "index.db"), embedder: "hash")
      requests = [
        { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        { jsonrpc: "2.0", id: 2, method: "tools/list" }
      ].map { |m| JSON.generate(m) }.join("\n") + "\n"

      code, out, = run_cli(["mcp", "--dir", dir], inp: StringIO.new(requests), home: File.join(dir, "home"))
      assert_equal 0, code
      responses = out.each_line.map { |l| JSON.parse(l) }
      assert_equal 2, responses.length # initialize + tools/list (notification silent)
      assert_equal CCE::MCP::PROTOCOL_VERSION, responses[0]["result"]["protocolVersion"]
      assert_equal %w[context_search index_status record_feedback],
                   responses[1]["result"]["tools"].map { |t| t["name"] }
    end
  end

  def test_mcp_missing_index_still_serves
    with_tmpdir do |dir|
      req = JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call",
                          params: { name: "context_search", arguments: { query: "x" } }) + "\n"
      code, out, = run_cli(["mcp", "--dir", dir], inp: StringIO.new(req), home: File.join(dir, "home"))
      assert_equal 0, code
      resp = JSON.parse(out.lines.first)
      assert_match(/not indexed yet/, resp["result"]["content"].first["text"])
    end
  end

  def test_init_dispatch_writes_config_and_next_steps
    with_tmpdir do |dir|
      write_fixture(dir)
      code, out, = run_cli(["init", dir], home: File.join(dir, "home"))
      assert_equal 0, code
      assert_match(/CCE init/, out)
      assert_match(/Restart your editor/, out)
      assert File.exist?(File.join(dir, ".mcp.json"))
      assert File.exist?(File.join(dir, "CLAUDE.md"))
    end
  end

  def test_init_no_such_directory
    code, _out, err = run_cli(["init", "/no/such/dir/xyz"])
    assert_equal 2, code
    assert_match(/no such directory/, err)
  end

  def test_init_unknown_agent_is_error
    with_tmpdir do |dir|
      write_fixture(dir)
      code, _out, err = run_cli(["init", "--agent", "vim", dir], home: File.join(dir, "home"))
      assert_equal 1, code
      assert_match(/unsupported --agent/, err)
    end
  end
end
