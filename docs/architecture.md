# Architecture

This is the canonical architecture document for cce-ruby. It covers the design
goals, the component/pipeline model, the key modelling choices, the rationale
behind them, and — honestly — where this design would strain.

For the authoritative *behaviour*, see [`SPEC.md`](../SPEC.md). For how each
spec ambiguity was resolved, see [`DECISIONS.md`](DECISIONS.md).

## Design goals

CCE was built as a clean-room, test-first implementation of a shared
specification, with a sibling in Rust built from the same spec. That context
drives the goals, roughly in priority order:

1. **Determinism.** The same corpus and query must produce the same ranking and
   the same emitted scores, run to run and — by construction — across
   implementations. This is what makes cross-language *conformance* meaningful.
2. **Spec fidelity.** Behaviour follows [`SPEC.md`](../SPEC.md) exactly; where
   the spec is ambiguous, the resolution is recorded in [`DECISIONS.md`](DECISIONS.md).
3. **Locality and privacy.** Runs entirely on the local machine with no network
   calls by default. Your code never leaves your box.
4. **Simplicity over cleverness.** Small, single-responsibility modules;
   brute-force algorithms where the spec's "small corpus" assumption allows;
   minimal store schema. Easy to read against the spec.
5. **Testability.** Pure, injectable units with a deterministic, hermetic test
   suite (no network, no clock, no randomness).

## Component model

CCE is a small pipeline of single-responsibility modules under `lib/cce/`,
loaded through `lib/cce.rb`. Two data flows dominate: **index** (write path) and
**search** (read path). They meet at the on-disk `Store`.

| Module | Responsibility |
|---|---|
| `Config` | Normative constants (SPEC §3) and runtime config. |
| `NumericFormat` | Round-half-away-from-zero to 6dp, fixed-6 strings, canonical `(score desc, chunk_id asc)` sort. |
| `Tokenizer` | The one shared byte tokenizer (SPEC §4.1). |
| `Hashing` | FNV-1a-64 (SPEC §5.1). |
| `Embedder` / `HashEmbedder` | Cosine (dot product) and the deterministic hashing embedder. |
| `OllamaEmbedder` | Optional HTTP embedder behind the same interface (SPEC §11). |
| `Grammars` | Bridges `tree_sitter_language_pack` (grammar dylibs) to `ruby_tree_sitter` (parser). |
| `Chunker` | Tree-sitter chunking, import extraction, chunk id, token count (SPEC §4.2–4.4). |
| `Walker` | Recursive file walk with ignore rules and UTF-8/size filtering (SPEC §7.1). |
| `VectorStore` | In-memory brute-force cosine search (SPEC §6.2). |
| `KeywordStore` | In-memory BM25 index (SPEC §6.3). |
| `GraphStore` | File-level import graph + undirected neighbour lookup (SPEC §6.7). |
| `Retriever` | The hybrid pipeline: intent → candidates → RRF → confidence → blend → penalty → diversity → graph (SPEC §6). |
| `Store` | SQLite persistence of chunks, vectors, imports, whole-file token counts, metadata (SPEC §7, DASHBOARD-SPEC §3). |
| `Indexer` | Orchestrates the write path; reconstructs a `Retriever` from a store. |
| `Conformance` | Fixture harness emitting deterministic `conformance.json` (SPEC §8). |
| `Bench` | Benchmark runner + report generation (SPEC §10). |
| `Metrics::*` / `Dashboard::*` | v1.1 observability: event log, recorder, pure aggregator, and the loopback dashboard app/page/server (DASHBOARD-SPEC). |
| `CLI` | Argument parsing and command dispatch (SPEC §9; plus `feedback`/`dashboard`, DASHBOARD-SPEC §5). |

The **v1.1 dashboard/observability subsystem** is documented separately in
[`dashboard.md`](dashboard.md) (metrics pipeline, event schema, aggregation
formulas, and its own "where this would strain" note). It layers cleanly on top
of the engine: `index`/`search`/`feedback` append events to a persisted JSONL
log, a **pure** aggregator turns that log into KPIs/north-stars/series, and a
read-only, loopback-only web server renders it. It is the one place CCE uses
wall-clock time (injected for tests); the core pipeline above is unchanged.

### Index (write path)

```
CLI index
  → Indexer.index(root, store_path, embedder)
      → Walker.collect(root)                     # in-scope files (+ skipped count)
      → for each file:
          Chunker.chunk_file(content, rel)        # function/class chunks or module fallback
          Chunker.extract_imports(content, lang)  # graph edges (first import segment)
          embedder.embed_batch(chunk contents)    # 256-dim vectors
      → Store.create(store_path).write(records, file_imports, embedder)
```

The store is written idempotently: every write fully replaces the corpus, so
re-indexing the same directory yields byte-identical state (chunk IDs are
deterministic).

### Search (read path, fresh process)

```
CLI search
  → Indexer.retriever_from_store(store_path)
      → Store.open → chunks + vectors + file_imports
      → Retriever.new(chunks, embedder, vectors, file_imports)
  → Retriever#search(query, top_k, graph_enabled)
      1. tokenize; empty → []
      2. classify intent → fts_weight
      3. embed query
      4. VectorStore candidates (top_k×3)   → vrank, cosine per chunk
      5. KeywordStore candidates (top_k×3)  → frank (BM25)
      6. RRF over the union; normalise
      7. confidence = W_VECTOR·vector + W_KEYWORD·keyword + W_RECENCY·0
      8. final = 0.5·confidence + 0.5·norm_rrf; ×0.8 if test/doc path
      9. sort (score desc, id asc); per-file diversity cap (≤3), keep top_k
     10. if graph_enabled: pull neighbour-file chunks, append (×0.85 cosine)
```

## Key modelling choices

- **The store is the seam between write and read.** Search always runs from a
  freshly opened store in a separate process — no shared in-memory state carries
  over from indexing. This is enforced by a test that indexes and then searches
  via the real `bin/cce` subprocess.
- **Everything numeric flows through `NumericFormat`.** All ranking comparisons
  and all emitted scores are rounded half-away-from-zero to 6 decimals, with
  `chunk_id` ascending as the tie-break. This single choke point is what makes
  cross-implementation determinism achievable.
- **Deterministic identity.** Chunk IDs are
  `sha256("path:start:end:" + first-100-content-bytes)[0,16]`. Vectors persist
  as little-endian IEEE-754 doubles (`Array#pack("E*")`), portable across host
  byte order.
- **BM25 is recomputed on load, not stored.** The spec allows either; corpora
  are small, so recomputation keeps the store schema minimal (see D5).
- **Chunking walks the raw parse tree ourselves.** `ruby_tree_sitter` provides
  the parser; we select nodes and byte spans directly rather than relying on a
  query DSL, so spans follow the spec exactly.

## Design rationale

- **Why brute-force cosine and in-memory BM25?** The spec targets small corpora
  and demands exact, reproducible ranking. An approximate-nearest-neighbour
  index would add a dependency, a build step, and a source of nondeterminism for
  no benefit at this scale. Exact scan over every chunk is simple and, per
  [`BENCHMARKS.md`](BENCHMARKS.md), stays comfortably interactive (tens of ms).
- **Why a hashing embedder as the default?** A model-free FNV-1a hashing
  embedder is fully deterministic and machine-independent, so conformance and
  benchmarks mean the same thing everywhere. A real model would make vectors
  depend on weights, hardware, and library versions — fine for quality, fatal
  for cross-implementation equivalence. The optional Ollama embedder exists for
  users who want semantic quality and accept it is out of conformance scope.
- **Why prebuilt grammars instead of compiling C at runtime?** Using
  `tree_sitter_language_pack` dylibs avoids a runtime C build while keeping node
  selection under our control. The cost is a one-time grammar download and a
  dependency on the language pack's grammar set (see D1).
- **Why full-rebuild idempotency instead of incremental updates?** Deterministic
  chunk IDs make a delete-all/insert-all write trivially correct and idempotent.
  Incremental, per-file updates would be faster on large repos but add
  substantial complexity for a use case the spec does not target (see D6).
- **Why localhost-only, opt-in networking?** Privacy and reproducibility. The
  default path never touches the network; the one optional path is localhost
  HTTP to Ollama and fails gracefully.

## Determinism (how it is guaranteed)

All ranking comparisons and all emitted scores pass through `NumericFormat`:
rounded half-away-from-zero to 6 decimals, ties broken by `chunk_id` ascending.
Vectors are persisted as little-endian IEEE-754 doubles. Chunk IDs are content-
and location-derived hashes. Together these make both the ranking and the
emitted `conformance.json` reproducible run-to-run and across implementations.

## Grammar loading

`ruby_tree_sitter` provides the parser but needs a compiled grammar. Rather than
compile C at runtime, `Grammars` asks `tree_sitter_language_pack` to prefetch
prebuilt Python/JavaScript dylibs into its cache, then loads them via
`TreeSitter::Language.load`. This keeps chunking under our exact control (we walk
the raw parse tree ourselves for precise byte spans) while avoiding a build step.

## Where this design would strain

Being honest about the edges of the design:

- **Large repositories.** Brute-force cosine and in-memory BM25 are O(corpus)
  per query, and the whole index is loaded into memory on every search. This is
  a deliberate fit for small corpora; on a very large monorepo, query latency
  and memory would grow linearly and the "load everything, scan everything"
  model would stop being interactive. An ANN index and on-disk/streamed scoring
  would be needed — at the cost of the determinism the spec prizes.
- **Full re-index on every change.** Idempotency via full rebuild means editing
  one file re-chunks and re-embeds the entire tree. Fine for small repos;
  wasteful at scale. Incremental indexing keyed on file hashes would be the
  escape hatch, adding real complexity.
- **Retrieval quality of the hash embedder.** The default embedder is
  effectively lexical — it captures identifier overlap, not semantics. Queries
  phrased differently from the code's identifiers will under-retrieve. The
  Ollama embedder addresses this but leaves conformance behind; the two goals
  (semantic quality vs. cross-impl determinism) genuinely pull apart here.
- **Language coverage.** Chunking depends on the grammars shipped by
  `tree_sitter_language_pack` (Python and JavaScript in practice). Files in other
  languages fall back to a whole-file "module" chunk — indexed and searchable,
  but not chunked at function/class granularity. Adding a language means adding
  a grammar and node-type rules.
- **Parser robustness on hostile input.** Indexed files are untrusted data fed
  to a native parser (see [`../SECURITY.md`](../SECURITY.md)). A pathological or
  malicious input could stress `ruby_tree_sitter`/the grammar. CCE never
  executes indexed code and treats parse output as data, but the native surface
  is the sharpest edge of the trust boundary.
- **Cross-implementation drift risk.** Determinism holds only as long as both
  implementations perform the same operations in the same order in IEEE-754 and
  round at the same boundaries. A subtle refactor that reorders floating-point
  accumulation could, in principle, diverge in the last decimal — which is why
  rounding is centralised and conformance is a gate.
