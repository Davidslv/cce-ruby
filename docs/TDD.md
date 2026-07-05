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

## Final result

```
84 runs, 213 assertions, 0 failures, 0 errors, 1 skips

Line Coverage: 94.19% (940 / 998)
Branch Coverage: 72.76% (179 / 246)
```

- **Test count:** 84 tests (1 skipped: the live Ollama integration test, which
  requires a running server and is intentionally excluded from the hermetic
  default suite).
- **Line coverage:** 94.19% overall (SimpleCov, `test/` and `vendor/` filtered).
  This exceeds the §12 target of ≥85% of non-CLI logic; the CLI itself is also
  exercised end-to-end including a real subprocess run.

The 1 skip is expected and hermetic. To run it: `CCE_OLLAMA_TEST=1 bundle exec
rake test` with a local Ollama server on `:11434`.
