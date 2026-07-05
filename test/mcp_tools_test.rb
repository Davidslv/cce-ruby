# WHY: The tool output SHAPE is the cross-language contract (SPEC-MCP §Tools) and
#      the text formatting has branches (workspace members, sync freshness,
#      no-results, capped context) that the server-level tests don't all reach.
#      Testing the pure formatters directly pins that contract cheaply.
# WHAT: Unit tests for CCE::MCP::Tools formatting/dispatch against stub statuses.

require_relative "test_helper"

class McpToolsTest < Minitest::Test
  # A tiny stub Context so the formatters are exercised without a real store.
  StubContext = Struct.new(:status) do
    def index_status = status
  end

  def call_status(status)
    res = CCE::MCP::Tools.call(StubContext.new(status), "index_status", {})
    res["content"].first["text"]
  end

  def test_status_not_indexed
    text = call_status(indexed: false, sync: { source: "local" })
    assert_match(/Not indexed/, text)
    assert_match(/run `cce index`/i, text)
  end

  def test_status_workspace_members_and_edges
    text = call_status(
      indexed: true, workspace: true, store_path: "/w/.cce",
      chunk_count: 12, file_count: 5,
      members: [
        { name: "app", type: "rails", indexed: true, files: 3, chunks: 8 },
        { name: "web", type: "node", indexed: false }
      ],
      edges: [{ from: "app", to: "web" }],
      sync: { configured: false, source: "local" }
    )
    assert_match(/Workspace index/, text)
    assert_match(/app \[rails\]: 3 files, 8 chunks/, text)
    assert_match(/web \[node\]: \(not indexed\)/, text)
    assert_match(/edges:      1/, text)
  end

  def test_status_sync_configured_behind_remote
    text = call_status(
      indexed: true, store_path: "/p/.cce/index.db", chunk_count: 3, file_count: 2,
      by_language: { "python" => 3 }, by_kind: { "function_definition" => 3 },
      embedder: "hash", last_indexed: "2026-07-05T10:00:00Z",
      sync: { configured: true, auto_pull: true, source: "sync-pull",
              sha: "a" * 40, remote_latest: "b" * 40, behind_remote: true }
    )
    assert_match(/source:     sync-pull \(aaaaaaaaaaaa\)/, text)
    assert_match(/sync:       configured \(auto_pull=on\)/, text)
    assert_match(/remote:     bbbbbbbbbbbb/, text)
    assert_match(/behind:     yes — a newer index is available/, text)
  end

  def test_status_sync_up_to_date_and_unreachable_labels
    up = call_status(indexed: true, store_path: "x", chunk_count: 0, file_count: 0,
                     sync: { configured: true, auto_pull: false, source: "local",
                             remote_latest: :unreachable, behind_remote: nil })
    assert_match(/auto_pull=off/, up)
    assert_match(/remote:     \(unreachable\)/, up)
    assert_match(/behind:     \(unknown\)/, up)

    none = call_status(indexed: true, store_path: "x", chunk_count: 0, file_count: 0,
                       sync: { configured: true, auto_pull: true, source: "local",
                               remote_latest: nil, behind_remote: false })
    assert_match(/remote:     \(none\)/, none)
    assert_match(/behind:     no — up to date/, none)
  end

  def test_context_search_no_results_text
    text = CCE::MCP::Tools.format_search([], "qid42", max_tokens: nil)
    assert_match(/No results/, text)
    assert_match(/qid42/, text)
  end

  def test_context_search_body_truncated_by_max_tokens
    results = [{ rank: 1, score: 0.9, file_path: "a.rb", start_line: 1, end_line: 9,
                 chunk_type: "function", kind: "method", token_count: 100,
                 content: "x" * 400 }]
    capped = CCE::MCP::Tools.format_search(results, "q", max_tokens: 2)
    assert_includes capped, "…"
    assert_operator capped.length, :<, 400
  end
end
