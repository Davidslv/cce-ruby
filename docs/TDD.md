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

## Final result

```
118 runs, 400 assertions, 0 failures, 0 errors, 1 skips

Line Coverage: 93.08% (1291 / 1387)
Branch Coverage: 75.32% (238 / 316)
```

- **Test count:** 118 tests (84 from v1.0 + 34 for v1.1; 1 skipped: the live
  Ollama integration test, requiring a running server and intentionally excluded
  from the hermetic default suite).
- **Line coverage:** 93.08% overall (SimpleCov, `test/` and `vendor/` filtered),
  comfortably above the ≥85% target. The base engine's `conformance.json` remains
  byte-for-byte identical to v1.0.

The 1 skip is expected and hermetic. To run it: `CCE_OLLAMA_TEST=1 bundle exec
rake test` with a local Ollama server on `:11434`.
