# CCE Benchmarks

Generated with `cce bench <repo> --lang <language>` (SPEC-V2 §8). Each language is
indexed from a pinned tag of a real repository with the default deterministic
hashing embedder, then measured on ten labelled queries. Python and JavaScript are
validated packs but are not benchmarked.

**Corpus scope.** `cce bench` indexes the **whole repository exactly as `cce
index` does**: pack-matched files (`.rb`, `.rs`, `.ts`/`.tsx`, `.c`/`.h`, `.py`,
`.js`/…) are AST-chunked into function/class chunks, and every other in-scope text
file becomes a single fallback `module` chunk — all under the normal walk ignore
rules (`.git`, `.cce`, `node_modules`, `.venv`/`venv`, `__pycache__`, `dist`,
`build`, any dotdir; non-UTF-8 and files > 2 MB skipped). There is no
bench-specific corpus filtering, so both implementations benchmark the identical
whole-repo corpus.

## Environment

| Field | Value |
|---|---|
| Runtime | Ruby 3.4.7 (arm64-darwin) |
| Embedder | hash (deterministic, model-free) |
| Machine | Apple Silicon (arm64, Darwin) |

## Per-language results

| Language | Repo (tag) | Commit | Files | Chunks | Index s | Chunks/s | p50 | p95 | Recall@5 | Recall@10 | Token savings |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Ruby | `sinatra/sinatra` (v4.1.1) | `7b50a1bb` | 287 | 1337 | 0.818 | 1635 | 18.1 ms | 19.3 ms | 90.0% | 90.0% | 72.6% |
| Rust | `sharkdp/hyperfine` (v1.19.0) | `12fec420` | 59 | 368 | 0.265 | 1387 | 5.3 ms | 6.4 ms | 60.0% | 80.0% | 42.1% |
| TypeScript | `pmndrs/zustand` (v5.0.3) | `3f9127f4` | 111 | 1278 | 0.603 | 2118 | 17.0 ms | 18.4 ms | 70.0% | 80.0% | 47.5% |
| C | `jqlang/jq` (jq-1.7.1) | `71c2ab50` | 294 | 1667 | 1.654 | 1008 | 22.4 ms | 23.7 ms | 60.0% | 70.0% | 77.4% |

Recall is the fraction of the ten labelled queries whose top-K result set contains
a file matching the expected path substring; token savings is `1 − served/baseline`
averaged over the query set (chunks served vs. whole result files). "Index s" is
wall-clock indexing time for the whole repository. Latency figures are the median
and 95th-percentile over the labelled query set, five repetitions each.

## Interpretation

Across four very different languages the pipeline behaves as the design predicts.
With the deterministic hashing embedder, retrieval is essentially lexical, so
recall tracks how directly a query's words overlap the target file's identifiers:
Ruby (sinatra) tops the table at 90% because Sinatra concentrates behaviour in a
small number of well-named files (`base.rb`, `show_exceptions.rb`), while the C
(jq) and Rust (hyperfine) corpora spread a concept across headers/modules whose
names are terser, so a keyword query lands a bit less often — an embedding model
(the opt-in Ollama backend) would close that gap at the cost of conformance
determinism. Token savings are large everywhere (42–77%): the engine serves a
handful of function/class chunks instead of whole files, and the ratio rises with
average file size (jq's large C sources save the most). Latency is dominated by
exact brute-force cosine plus BM25 over every chunk (no ANN index, by design) and
scales with corpus size — from ~5 ms on hyperfine's 368 chunks to ~22 ms on jq's
1667 — comfortably interactive at these sizes. Because the whole-repo corpus,
chunking, and query sets are identical across implementations, Recall@5/@10 and
token-savings numbers must match the sibling Rust implementation on the same
pinned commits exactly; only latency (language- and runtime-dependent) differs.
