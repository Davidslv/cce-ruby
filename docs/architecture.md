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
| `Grammars` | Bridges `tree_sitter_language_pack` (grammar dylibs) to `ruby_tree_sitter` (parser); language-agnostic. |
| `Packs::*` | One `LanguagePack` per language (`packs/<name>.rb`): extensions, function/class node types, import rule, self-test sample (SPEC-V2 §1–2). |
| `PackRegistry` | Resolves a file to its pack by extension; rejects a duplicate-extension registration (SPEC-V2 §1.1). |
| `PackValidator` | Structural / grammar-binding / behavioural validation of a pack, with "did you mean" node-kind suggestions (SPEC-V2 §5). |
| `Chunker` | Registry-driven chunking, import extraction, chunk id, token count, per-chunk `kind` — holds no language knowledge (SPEC §4.2–4.4, SPEC-V2 §1, §3). |
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
  → Indexer.index(root, store_path, embedder, allow_secrets:)
      → Walker.collect(root, allow_secrets:)     # in-scope files (+ skipped + sensitive_skipped)
                                                 #   Layer 1: Sensitive.sensitive?(basename) → never read
      → for each file:
          content = Redactor.redact(content)      # Layer 2: strip inline secrets → [REDACTED:LABEL]
          Chunker.chunk_file(content, rel)        # pack-driven function/class chunks (+ kind) or module fallback
          Chunker.extract_imports(content, rel)   # graph edges via the file's pack
          embedder.embed_batch(chunk contents)    # 256-dim vectors
      → Store.create(store_path).write(records, file_imports, embedder)
```

The store is written idempotently: every write fully replaces the corpus, so
re-indexing the same directory yields byte-identical state (chunk IDs are
deterministic).

**Secret protection (v2.1) is a write-path concern, split into two layers that
both sit before persistence.** *Layer 1* (`CCE::Sensitive`, consulted by the
walker) decides from a file's basename alone whether it is too sensitive to ever
read — a private key, a credential file, a `.env` — and tallies it separately as
`sensitive_skipped`. *Layer 2* (`CCE::Redactor`, applied by the indexer) scrubs
high-confidence secrets out of each file's content **before** chunking, so
`chunk_id`, `token_count`, the embedding, and the stored row all derive from the
redacted text and the store never contains the secret. Both are deterministic and
default-on; `--allow-secrets` disables both for a run. The seven sample fixtures
carry no secrets, so both layers are no-ops over them and `conformance.json` is
unchanged.

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
compile C at runtime, `Grammars` asks `tree_sitter_language_pack` to prefetch the
prebuilt dylib for a grammar *name* into its cache, then loads it via
`TreeSitter::Language.load`. `Grammars` knows how to find and load a grammar but
nothing about what any language means — each pack declares its own `grammar_name`.
This keeps chunking under our exact control (we walk the raw parse tree ourselves
for precise byte spans) while avoiding a build step.

## Language packs (v2.0)

The engine holds **zero** language-specific knowledge. Everything a language
needs is declared by a **`LanguagePack`** (`lib/cce/packs/<name>.rb`):

| Member | Meaning |
|---|---|
| `name` / `extensions` | unique id and the file extensions it claims (leading dot, lowercase) |
| `grammar_name` → `grammar` | the tree-sitter grammar to parse with |
| `function_types` / `class_types` | AST node types that become `function` / `class` chunks |
| `import_node_types` / `extract_imports` | the node types it inspects, and the ordered, de-duplicated import names it yields |
| `sample` / `expected` | a self-test snippet and what it must produce (counts, kinds, exact imports) |

The **`PackRegistry`** owns the set of packs and resolves a path to its pack by
extension (`pack_for`), rejecting any registration whose extension is already
claimed. The `Chunker` is generic: `pack = registry.pack_for(path)`; if `nil`,
emit the language-neutral `module` fallback; otherwise parse with `pack.grammar`,
walk the tree, and emit a chunk for every **named** node whose type is in
`function_types`/`class_types` — nested ones too (a method inside a class yields
both chunks; a Rust `impl` and its `fn`s both emit). Import extraction is likewise
delegated to the pack. **A test asserts the core chunker/importer name no language
and no extension literal**, so this indirection cannot silently rot.

### Chunk taxonomy: `chunk_type` + `kind`

Every chunk carries two labels. `chunk_type` is the coarse bucket used by the
rest of the engine — `function`, `class`, or `module` (fallback) — deliberately
unchanged, because retrieval ranks on content and path, not on the label. `kind`
is the **exact tree-sitter node type** that produced the chunk
(`struct_specifier`, `trait_item`, `interface_declaration`, `method`, …; `module`
for the fallback). `kind` is deterministic straight from the node type, so both
implementations agree trivially; it is carried through persistence, surfaced in
`search`/`stats`/dashboard, and appears in `conformance.json`. It does **not**
affect scoring, RRF, penalties, or `chunk_id`.

### Validators (the safety rail)

A pack is compatible iff it passes three layers (`PackValidator`, surfaced via
`cce packs --validate`, a CI test-gate, and cheap fail-fast startup checks):

1. **Structural** — name present and unique; ≥1 lowercase leading-dot extension;
   no extension claimed twice; the full interface is implemented.
2. **Grammar-binding** — the grammar loads and every string in `function_types`,
   `class_types`, and `import_node_types` is a real node kind in that grammar. On
   a miss it suggests the nearest valid kinds by edit distance ("did you mean").
3. **Behavioural** — run the pack over its own `sample` and assert the minimum
   function/class counts, the required `kind`s, **and `extract_imports == expected`
   exactly**. This catches a pack that is structurally valid but wired to the
   wrong node type, and pins import extraction.

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
  `tree_sitter_language_pack`. Six languages ship as packs (Ruby, Rust,
  TypeScript, C, Python, JavaScript); files in any other language fall back to a
  whole-file `module` chunk — indexed and searchable, but not chunked at
  function/class granularity. Adding a language is *one pack file + register it +
  `cce packs --validate`* — no core edits (see
  [`adding-a-language.md`](adding-a-language.md)).
- **One extension → one pack.** The registry maps each extension to exactly one
  pack, so a file's language is decided purely by its extension. This is simple
  and fast but strains where a single extension carries multiple dialects that
  need *content* to disambiguate — `.h` is claimed by the C pack yet is also used
  by C++/Objective-C headers, and `.ts` vs `.tsx` (and JSX-in-`.js`) are real
  grammar dialects the packs approximate with one grammar each. Per-file dialect
  detection would mean resolving a pack from content, not just the extension —
  more power, but it gives up the "extension is destiny" simplicity and the
  trivially-deterministic resolution the conformance gate leans on.
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

## Workspaces (v2.2)

Workspace mode (SPEC-V2.2) layers an *ecosystem* view over the single-repo engine
without changing it. It lives entirely under `CCE::Workspace` and is purely
additive: absent `--workspace`, every command and the `conformance.json` output
are untouched.

- **Federated, not centralised.** The three pillars are auto-detection into a
  reviewable manifest, federated storage (each member indexed into its *own*
  `<member>/.cce/` by the normal pipeline), and Level-1 cross-member dependency
  edges. The only central state is two metadata files at the root
  (`workspace.yml`, `workspace-graph.json`). A member's store is **byte-identical
  to indexing it standalone**, which is what keeps per-member isolation — and the
  per-member conformance gate — intact.
- **Federation is defined as the union.** `FederatedRetriever` builds a single
  ordinary `Retriever` over the concatenation of the in-scope members' stored
  chunks. This makes "a workspace search equals one §6 retrieval over the union"
  literally true by construction, so the equivalence is provable rather than
  approximated. Cross-member graph hops are a bounded expansion layered on top,
  driven by the manifest-derived edges, so they never perturb the base ranking.
- **Component model.** `Detector` (markers → members) → `Manifest` (deterministic
  YAML) → `Dependencies` (manifest parsing) → `Graph` (edges) → `Indexer`
  (per-member indexing + graph) → `Federation`/`FederatedRetriever` (search) and
  `Stats`/`Dashboard` (federated views). Each has one concern and a why/what
  header; none owns retrieval or persistence — they compose the existing pieces.
- **Where it strains.** Reloading many member stores per query bounds how large an
  ecosystem stays fast; edges are limited to *declared* manifest dependencies
  (not Rails route mounting or path aliases yet); detection is heuristic, which is
  why the manifest is generated once and then hand-editable. See
  [`workspace.md`](workspace.md) for the full treatment.

## CCE Sync (v2.3)

CCE Sync (SPEC-SYNC) adds an optional, offline-first, content-addressed cache over
a git remote. It lives entirely under `CCE::Sync` and is purely additive: absent a
configured `sync.remote`, nothing runs and every command — and the single-repo
`conformance.json` — is untouched.

- **Determinism is the whole trick.** The index is a pure function of
  `(repo@sha, cce version, pack set, hash embedder)`, so a cache for `repo@sha` is
  content-addressable — no "whose version wins", no merge. A teammate's push, CI's
  push, and a fresh local build are bit-for-bit identical, which is what makes a
  pull safe and `verify` (rebuild-and-compare) meaningful. Only the deterministic
  hash embedder qualifies; Ollama indexes are local-only and `push` refuses them.
- **The artifact is a third format, not either native store.** Ruby stores SQLite
  and Rust stores JSON, so the interchange artifact (`Sync::Artifact`) is a
  canonical, byte-exact, newline-delimited stream: a manifest line, one compact
  sorted-key JSON object per chunk (sorted by `(file_path, start_line, chunk_id)`),
  then the import graph. Embeddings are **base64 of 256 little-endian IEEE-754
  `f64` bytes** so the vectors are bit-identical regardless of float→string
  formatting. The `checksum` is SHA-256 over the canonical bytes with the
  provenance keys (`checksum`, `built_at`, `built_by`) excluded — those differ
  between builders and would otherwise break the cross-language byte-identity the
  whole scheme depends on. Import recomputes each chunk's `language` from its path
  (a pure function via the pack registry), so the artifact need not carry it.
- **The remote is plain git, keyed by content address.** `Sync::ContentAddress`
  builds `<embedder>/<cce_ver>/<repo_id>/<sha>.cce`; `Sync::GitRemote` is a working
  clone under `~/.cce/sync/<remote-id>/` implementing `put`/`get`/`has`/`list`/
  `latest`. Distinct shas are distinct files, so the only race is git-ref
  advancement — handled with fetch → rebase → retry. `*.cce` blobs route through
  git-LFS by default. Auth/permissions are git's; CCE adds no RBAC (SPEC-SYNC §6).
- **Component model.** `ContentAddress` (keying) + `Artifact` (export/import/
  checksum) + `Git` (a thin CLI wrapper) + `GitRemote` (the `SyncRemote` backend)
  + `Config` (layered `sync.*`) compose into `Sync::Commands`, the per-project
  engine that holds the offline-first contract: refuse a dirty tree / non-hash
  index on `push`, validate-and-install on `pull`, guard overwrites of a different
  `sha`, rebuild-and-compare on `verify`, and translate every git/remote failure
  into a clear `Sync::Error` so local work is never corrupted. The CLI is a thin
  formatter; workspace mode reuses `Commands` per member with a `repo_id__<package>`
  override, so a workspace is just N repos sharing one remote.
- **Where it strains (documented next steps).** The branch overlay (incremental
  reindex of changed files on top of a pulled base) is out of scope in v1 — a
  differing working tree falls back to a normal local `cce index`. Whole-file token
  counts (a dashboard-only baseline, DASHBOARD §3) are not carried in the artifact,
  since they are not reconstructable from chunks alone and are irrelevant to search
  results and stats; a pulled store recomputes them on the next local `cce index`.
  Non-git backends (S3/HTTP) and a read-only Sourcegraph adapter are possible
  through the same `SyncRemote` interface without CLI changes. See
  [`sync.md`](sync.md) for the full treatment.
