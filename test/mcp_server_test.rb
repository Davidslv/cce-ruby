# WHY: The MCP server is a wire protocol an editor drives over stdio; it must be
#      exactly right (handshake, routing, error framing) and never crash. These
#      tests drive it hermetically by piping JSON-RPC to an input IO and asserting
#      the output IO — no editor, no network (SPEC-MCP §Testing).
# WHAT: JSON-RPC 2.0 framing + MCP handshake/routing tests over a fixture index.

require_relative "test_helper"
require "stringio"

class McpServerTest < Minitest::Test
  include TestSupport

  # Build a context over a freshly-indexed fixture dir, with deterministic ids.
  def with_indexed_context
    with_tmpdir do |dir|
      write_fixture(dir)
      CCE::Indexer.index(dir, store_path: File.join(dir, ".cce", "index.db"), embedder: "hash")
      ctx = CCE::MCP::Context.new(
        dir: dir, home: File.join(dir, "home"),
        clock: CCE::Metrics::FixedClock.new("2026-07-05T10:00:00Z"),
        id_source: CCE::Metrics::SequenceIdSource.new(%w[qid000000001 qid000000002 qid000000003])
      )
      yield ctx, dir
    end
  end

  # Run the server over a list of JSON-RPC request hashes; return parsed responses.
  def drive(ctx, messages)
    input = StringIO.new(messages.map { |m| JSON.generate(m) }.join("\n") + "\n")
    output = StringIO.new
    CCE::MCP::Server.new(context: ctx, input: input, output: output, version: "9.9.9").run
    output.string.each_line.map { |l| JSON.parse(l) }
  end

  def test_initialize_handshake
    with_indexed_context do |ctx, _dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }]).first
      assert_equal "2.0", resp["jsonrpc"]
      assert_equal 1, resp["id"]
      assert_equal CCE::MCP::PROTOCOL_VERSION, resp["result"]["protocolVersion"]
      assert_equal({ "tools" => {} }, resp["result"]["capabilities"])
      assert_equal "cce", resp["result"]["serverInfo"]["name"]
      assert_equal "9.9.9", resp["result"]["serverInfo"]["version"]
    end
  end

  def test_initialized_notification_gets_no_response
    with_indexed_context do |ctx, _dir|
      out = drive(ctx, [{ jsonrpc: "2.0", method: "notifications/initialized" }])
      assert_empty out
    end
  end

  def test_ping
    with_indexed_context do |ctx, _dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 7, method: "ping" }]).first
      assert_equal({}, resp["result"])
    end
  end

  def test_tools_list_exact_contract
    with_indexed_context do |ctx, _dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 2, method: "tools/list" }]).first
      tools = resp["result"]["tools"]
      assert_equal %w[context_search index_status record_feedback], tools.map { |t| t["name"] }

      cs = tools.find { |t| t["name"] == "context_search" }
      assert_match(/PREFERRED tool/, cs["description"])
      props = cs["inputSchema"]["properties"]
      assert_equal "string", props["query"]["type"]
      assert_equal 8, props["top_k"]["default"]
      assert_equal "string", props["package"]["type"]
      assert_equal false, props["no_graph"]["default"]
      assert_equal "integer", props["max_tokens"]["type"]
      assert_equal ["query"], cs["inputSchema"]["required"]

      rf = tools.find { |t| t["name"] == "record_feedback" }
      assert_equal %w[query_id helpful], rf["inputSchema"]["required"]
    end
  end

  def test_tools_call_context_search_returns_results_and_query_id
    with_indexed_context do |ctx, dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 3, method: "tools/call",
                           params: { name: "context_search", arguments: { query: "hash password" } } }]).first
      text = resp["result"]["content"].first["text"]
      assert_equal false, resp["result"]["isError"]
      assert_match(/auth\.py/, text)
      assert_match(/query_id: qid000000001/, text)
      # metrics event written to .cce/metrics.jsonl
      log = File.join(dir, ".cce", "metrics.jsonl")
      assert File.exist?(log)
      events = File.readlines(log).map { |l| JSON.parse(l) }
      search = events.find { |e| e["event"] == "search" }
      assert_equal "hash password", search["query"]
      assert_equal "qid000000001", search["id"]
    end
  end

  def test_tools_call_context_search_missing_query_is_error
    with_indexed_context do |ctx, _dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 4, method: "tools/call",
                           params: { name: "context_search", arguments: {} } }]).first
      assert_equal true, resp["result"]["isError"]
      assert_match(/requires a non-empty 'query'/, resp["result"]["content"].first["text"])
    end
  end

  def test_tools_call_index_status
    with_indexed_context do |ctx, _dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 5, method: "tools/call",
                           params: { name: "index_status", arguments: {} } }]).first
      text = resp["result"]["content"].first["text"]
      assert_match(/Index status/, text)
      assert_match(/chunks:/, text)
      assert_match(/source:     local/, text)
    end
  end

  def test_tools_call_record_feedback_appends_event
    with_indexed_context do |ctx, dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 6, method: "tools/call",
                           params: { name: "record_feedback",
                                     arguments: { query_id: "qid000000001", helpful: true, note: "great" } } }]).first
      assert_equal false, resp["result"]["isError"]
      log = File.join(dir, ".cce", "metrics.jsonl")
      fb = File.readlines(log).map { |l| JSON.parse(l) }.find { |e| e["event"] == "feedback" }
      assert_equal "qid000000001", fb["target_id"]
      assert_equal true, fb["helpful"]
      assert_equal "great", fb["note"]
    end
  end

  def test_record_feedback_requires_boolean
    with_indexed_context do |ctx, _dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 8, method: "tools/call",
                           params: { name: "record_feedback", arguments: { query_id: "x" } } }]).first
      assert_equal true, resp["result"]["isError"]
      assert_match(/boolean 'helpful'/, resp["result"]["content"].first["text"])
    end
  end

  def test_unknown_method_is_method_not_found
    with_indexed_context do |ctx, _dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 9, method: "does/not/exist" }]).first
      assert_equal(-32_601, resp["error"]["code"])
    end
  end

  def test_unknown_tool_is_error_result
    with_indexed_context do |ctx, _dir|
      resp = drive(ctx, [{ jsonrpc: "2.0", id: 10, method: "tools/call",
                           params: { name: "bogus", arguments: {} } }]).first
      assert_equal true, resp["result"]["isError"]
      assert_match(/unknown tool/, resp["result"]["content"].first["text"])
    end
  end

  # A tool raising an unexpected error must become a JSON-RPC internal error, not
  # a crashed server (SPEC-MCP: the server never dies).
  def test_tool_raise_becomes_internal_error
    raising = Object.new
    def raising.search(*) = raise("boom")
    input = StringIO.new(JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call",
                                       params: { name: "context_search",
                                                 arguments: { query: "x" } }) + "\n")
    output = StringIO.new
    CCE::MCP::Server.new(context: raising, input: input, output: output).run
    resp = JSON.parse(output.string.lines.first)
    assert_equal(-32_603, resp["error"]["code"])
    assert_match(/boom/, resp["error"]["message"])
  end

  def test_parse_error_is_framed_not_crash
    with_indexed_context do |ctx, _dir|
      input = StringIO.new("this is not json\n")
      output = StringIO.new
      CCE::MCP::Server.new(context: ctx, input: input, output: output).run
      resp = JSON.parse(output.string.lines.first)
      assert_nil resp["id"]
      assert_equal(-32_700, resp["error"]["code"])
    end
  end

  def test_blank_lines_are_skipped
    with_indexed_context do |ctx, _dir|
      input = StringIO.new("\n\n#{JSON.generate(jsonrpc: '2.0', id: 1, method: 'ping')}\n\n")
      output = StringIO.new
      CCE::MCP::Server.new(context: ctx, input: input, output: output).run
      assert_equal 1, output.string.lines.length
    end
  end

  def test_max_tokens_caps_output
    with_indexed_context do |ctx, _dir|
      full = drive(ctx, [{ jsonrpc: "2.0", id: 1, method: "tools/call",
                           params: { name: "context_search", arguments: { query: "hash password" } } }]).first
      capped = drive(ctx, [{ jsonrpc: "2.0", id: 2, method: "tools/call",
                             params: { name: "context_search", arguments: { query: "hash password", max_tokens: 1 } } }]).first
      assert_operator capped["result"]["content"].first["text"].length,
                      :<, full["result"]["content"].first["text"].length
    end
  end
end
