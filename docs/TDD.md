# TDD log

Built strictly test-first: for each unit of behaviour a failing test was written
to pin the spec, then the minimum code to pass it, then a refactor with the suite
green. Every anchor and required case from SPEC §12 is covered.

## Build order (red → green)

1. **Tokenizer** (`test/tokenizer_test.rb`) — SPEC §4.1 anchors first.
   - Notable red→green: my initial `"café naïve"` expectation was wrong; the spec
     makes *each* non-ASCII byte a separator, so multi-byte codepoints split a
     run. Fixed the test to `["caf","na","ve"]` — the implementation was correct.
2. **Hashing + hash embedder + cosine** (`test/embedder_test.rb`) — the published
   FNV-1a-64 vectors, embed normalisation, and the cosine anchor `0.6`. Green on
   first implementation.
3. **Chunker** (`test/chunker_test.rb`) — fixture structural counts, line spans,
   chunk types, fallback, imports, deterministic chunk id, token count.
   - Notable red→green #1: `ruby_tree_sitter` could not find the grammar dylib
     because I double-appended `/libs` to the language-pack cache dir. Fixed the
     path resolution.
   - Notable red→green #2: `node.type` returns a **Symbol**, not a String, so all
     node-type set membership checks silently failed and every file fell back to a
     module chunk. Normalised comparisons to `to_s`.
   - Notable design point: settled the fallback `end_line` rule empirically
     against tree-sitter's own line numbering (`count("\n")+1`) — see
     `docs/DECISIONS.md` D2.
4. **Keyword store / BM25** (`test/keyword_store_test.rb`) — reproduced the worked
   anchor `score(D1)=0.902273` to ±1e-4 and the zero-score exclusion rule.
5. **Vector store** (`test/vector_store_test.rb`) — cosine ranking, candidate
   cap, per-chunk cosine lookup.
6. **Graph store** (`test/graph_store_test.rb`) — edge resolution by stem,
   undirected neighbours, unresolved-module rejection.
7. **Retriever** (`test/retriever_test.rb`) — intent classification, the RRF
   anchor `1/60 + 1/62 = 0.032796`, path penalty, diversity cap, graph expansion,
   and the three conformance top-1s on the fixture.
8. **Walker** (`test/walker_test.rb`) — ignore rules, oversized/non-UTF-8
   skipping, forward-slash relative paths.
9. **Store** (`test/store_test.rb`) — persistence round-trip (chunks, vectors,
   imports, embedder name), idempotent re-index.
10. **Conformance** (`test/conformance_test.rb`) — 7-chunk manifest, canonical
    sort, per-query top-1, fixed 6-decimal scores, and run-to-run determinism.
11. **Numeric format** (`test/numeric_format_test.rb`) — rounding, fixed-6
    strings (incl. no negative zero), canonical sort tie-break.
12. **Ollama** (`test/ollama_embedder_test.rb`) — interface + empty-input
    short-circuit + graceful unreachability; a live test skipped unless
    `CCE_OLLAMA_TEST=1` (keeps the default suite hermetic).
13. **Bench** (`test/bench_test.rb`) — percentile, hit detection, token savings,
    and an end-to-end run over a synthetic mini-repo (no network).
14. **CLI** (`test/cli_test.rb`) — index → stats → search happy path, JSON
    output, invalid inputs (exit codes), and a **fresh-process** index-then-search
    via the real `bin/cce` executable.

## Coverage of SPEC §12 required cases

| Required case | Test |
|---|---|
| Tokenizer anchors (§4.1) | `TokenizerTest` |
| FNV-1a anchors (§5.1) | `EmbedderTest#test_fnv1a64_*` |
| Cosine anchor (§5.2) | `EmbedderTest#test_cosine_anchor` |
| Chunk-ID determinism (§4.3) | `ChunkerTest#test_chunk_id_is_deterministic_and_matches_spec` |
| BM25 worked example (§6.3) | `KeywordStoreTest#test_worked_anchor_scores` |
| RRF anchor (§6.4) | `RetrieverTest#test_rrf_anchor` |
| Fixture chunking counts (§8.1) | `ChunkerTest`, `ConformanceTest#test_seven_chunks_*` |
| Ignore rules (§7.1) | `WalkerTest` |
| Three conformance top-1s (§8.2) | `RetrieverTest#test_q{1,2,3}_*`, `ConformanceTest#test_query_top1s` |
| Persistence round-trip / fresh process | `StoreTest`, `CLITest#test_fresh_process_index_then_search` |
| Graph edge extraction + expansion (§6.7) | `GraphStoreTest`, `RetrieverTest#test_graph_expansion_*` |
| CLI happy path + invalid input | `CLITest` |

## v1.1 — Dashboard & observability (DASHBOARD-SPEC §8)

Built test-first on the `feat/dashboard` branch, red → green, on top of the
unchanged v1.0 engine. Order: event log → recorder → aggregator anchor → store
file-token persistence → HTTP app/server → CLI wiring.

| Required case (DASHBOARD-SPEC §8) | Test |
|---|---|
| Event append w/ injected clock + id source | `MetricsRecorderTest` |
| `--no-metrics` / disabled suppresses writes | `MetricsRecorderTest#test_no_metrics_*`, `CLIMetricsTest#test_no_metrics_*` |
| Corrupt/blank-line robustness; missing path fail-open | `MetricsEventLogTest` |
| Whole-file token persistence (§3) + baseline sum | `StoreTest#test_file_token_counts_round_trip`, `CLIMetricsTest#test_search_baseline_*` |
| Aggregator ANCHOR (§4.1) — exact | `MetricsAggregatorTest` |
| Empty-log → valid "no data" aggregate | `MetricsAggregatorTest#test_empty_log_*` |
| Feedback event + resolution into recent searches | `MetricsAggregatorTest#test_recent_searches_*`, `CLIMetricsTest#test_feedback_*` |
| HTTP endpoints on an ephemeral loopback port | `DashboardServerTest`, `CLIMetricsTest#test_dashboard_command_serves_over_loopback` |

The metrics/dashboard tests inject `FixedClock`/`SequenceIdSource` (never the real
clock) and bind an ephemeral loopback port (never a real external network), so the
suite stays deterministic and hermetic despite the feature being time-based.

## v2.0 — pluggable language packs (test-first)

The v2 evolution was built the same way (SPEC-V2 §10). New tests were written
first for: the registry (resolution, duplicate-extension rejection), each pack's
self-test (counts, kinds, and exact imports over its §6 sample), all three
validator layers with their diagnostics (including a deliberately-broken pack
asserting a *helpful* message), the "core names no language" grep guard, the
`kind` field end-to-end (index → persist → search/stats/conformance), the fixed
module-fallback line count, and the v2 conformance output shape.

- Notable red→green: the Ruby pack initially reported **two** class chunks for a
  one-class sample. tree-sitter-ruby spells both the class definition node and the
  `class` keyword token `"class"`; the fix is to chunk only **named** nodes
  (`node.named?`) — recorded as decision D20. The behavioural self-test caught it.
- Grammar node-type spellings were taken from the grammars (parse a snippet, print
  the types), not from memory — exactly the loop the grammar-binding validator is
  designed to make cheap.

## Final result

```
164 runs, 803 assertions, 0 failures, 0 errors, 1 skips

Line Coverage: 93.33% (1666 / 1785)
Branch Coverage: 74.94% (314 / 419)
```

- **Test count:** 164 tests (118 from v1.0/v1.1 + 46 for v2.0; 1 skipped: the live
  Ollama integration test, requiring a running server and intentionally excluded
  from the hermetic default suite).
- **Line coverage:** 93.33% overall (SimpleCov, `test/` and `vendor/` filtered),
  at the ≥93% v2 target. `cce packs --validate` passes for all six packs, and the
  v2 `conformance.json` over the seven samples is byte-for-byte reproducible.

The 1 skip is expected and hermetic. To run it: `CCE_OLLAMA_TEST=1 bundle exec
rake test` with a local Ollama server on `:11434`.

> **Current baseline (v2.4.1).** The transcript above is the v2.0 milestone
> snapshot. The suite has grown test-first through v2.1 (secrets), v2.2
> (workspaces), v2.3 (Sync), v2.4 (MCP) and the v2.4.1 dashboard refresh to
> **372 runs, 1553 assertions, 0 failures, 0 errors, 1 skip · line coverage
> 94.78%** (≥ 93% held throughout). The single-repo `conformance.json` and the
> cross-engine sync golden (`581cbd0f…`, `SYNC_FORMAT_VERSION "2.3"`) are
> unchanged across all of it.
