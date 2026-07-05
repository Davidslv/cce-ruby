# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Test-only.** Pinned `test/fixture/workspace/` to the canonical byte-exact
  bytes shared with the sibling repo for cross-language parity. No behaviour
  change; SPEC-V2.2 §8 structural expectations still hold.

## [2.2.0] - 2026-07-05

Workspace mode (SPEC-V2.2) — CCE can now understand an **ecosystem** of related
codebases (e.g. a Rails app + engines + a frontend under one root) as a single
searchable whole, while **each member stays isolated** in its own store. This is
an additive minor release: absent `--workspace`, every command behaves exactly as
before, and the single-repo `conformance.json` is byte-for-byte unchanged.

### Added

- **Auto-detection + manifest.** `cce workspace init [<dir>] [--force]` walks the
  tree with the standard ignore rules and detects members by marker (`*.gemspec` →
  Ruby gem/engine; `Gemfile` + `config/application.rb` → Rails app; `package.json`
  → TypeScript/JavaScript). Members do not nest. It writes a deterministic,
  reviewable `<dir>/.cce/workspace.yml`. `cce workspace list` prints members and
  cross-member edges. New modules `CCE::Workspace::Detector` and `::Manifest`.
- **Federated indexing.** `cce index --workspace [<dir>]` indexes each member into
  its own `<member>/.cce/` via the normal pipeline (language packs + secret
  scrubbing inherited). A member's store is **byte-identical to indexing that
  member standalone** — isolation is preserved. New module `CCE::Workspace::Indexer`.
- **Cross-member dependency edges (Level 1).** Declared dependencies are read from
  each member's `*.gemspec` / `Gemfile` / `package.json`, and an edge `A → B` is
  recorded when a name `A` declares equals member `B`'s package (or name). Written
  deterministically to `<dir>/.cce/workspace-graph.json`. New modules
  `CCE::Workspace::Dependencies` and `::Graph`.
- **Federated search.** `cce search "q" --workspace [<dir>] [--package a,b]
  [--top-k N] [--no-graph] [--json]` runs the standard §6 retrieval once over the
  **union** of the in-scope members' chunks; each result is tagged with its
  member; the diversity key is `(member, file_path)`; graph expansion uses each
  member's intra-store import graph **plus** the cross-member edges. `--package`
  scopes to named members (errors on an unknown name). New module
  `CCE::Workspace::Federation` + `FederatedRetriever`.
- **Workspace stats & dashboard.** `cce stats --workspace` shows per-member metrics,
  totals, and edges. `cce dashboard --workspace` federates each member's
  `metrics.jsonl` into one read-only, loopback-only roll-up with a `by_package`
  breakdown. New modules `CCE::Workspace::Stats` and `::Dashboard`.
- **Fixture.** `test/fixture/workspace/` — a minimal ecosystem (`app` / `billing`
  / `web`) exercising detection, edges, isolation, federation == union, and the
  cross-member graph hop.

### Unchanged

- Single-repo `index` / `search` / `stats` / `dashboard` / `packs` and the
  secret-scrubbing layers behave exactly as in 2.1.0.
- The cross-language conformance output (`conformance.json`) is byte-identical.

## [2.1.0] - 2026-07-05

Secret & sensitive-file protection (SPEC-V2.1). Indexing becomes **secret-safe by
default** through two layers, so credential files never enter the corpus and
inline secrets are redacted before anything is chunked, embedded, or stored. This
is an additive, secure-by-default minor release — the public API and the
conformance output are unchanged.

### Added

- **Layer 1 — sensitive-file skipping (walker).** Files are classified by name
  before they are read: sensitive extensions (`pem key p12 pfx keystore jks ppk
  der asc`), exact credential basenames (`credentials.*`, `secrets.*`, `.netrc`,
  `.pgpass`, `.htpasswd`, `.dockercfg`, `kubeconfig`, `id_rsa`/`id_dsa`/`id_ecdsa`/
  `id_ed25519`), and the dotenv rule (`.env`/`.env.*` skipped, but
  `.example`/`.sample`/`.template`/`.dist` templates indexed). Matches are never
  read and are counted separately as `sensitive_skipped`. New module
  `CCE::Sensitive`.
- **Layer 2 — secret redaction (indexer).** Before chunking, each file's content
  is scrubbed for high-confidence secrets (AWS, GitHub, Slack, Stripe, OpenAI,
  Anthropic, Google keys; private-key blocks; JWTs; and a guarded generic
  `key = value` assignment) with each match replaced by `[REDACTED:<LABEL>]`. The
  redacted text is what is chunked, embedded, and stored. New module
  `CCE::Redactor`.
- **`--allow-secrets` flag on `index`.** Opt out of both layers for a run
  (default off ⇒ protection on); prints a warning when set.
- **Reporting.** The `index` summary now shows the `sensitive skipped` count.
- **End-to-end secrets tests** covering each Layer-1 category, the redactor (each
  label + a placeholder-guard negative), the fixture skip/redact behaviour, and
  the `--allow-secrets` bypass. The secret-bearing fixtures (`.env`, `id_rsa`,
  `config.rb`) are generated into a temp dir at runtime — their secret values are
  assembled from split fragments, so no committed file contains a contiguous
  secret-shaped literal (GitHub push protection stays green).

### Unchanged

- `conformance.json` is **byte-identical** — the sample fixtures carry no secrets
  and no sensitive filenames, so both layers are no-ops over them.

## [2.0.0] - 2026-07-05

Pluggable language packs (SPEC-V2 v2.0). Language support is reworked into a
self-contained **`LanguagePack`** architecture so the core engine holds zero
language-specific knowledge; four new languages ship; every chunk gains a `kind`
field; and validators make adding a language safe and self-diagnosing.

**This is a major, breaking release** — the conformance output shape changes and
the supported-language set changes.

### Breaking

- **Conformance output shape changed.** Each chunk in `conformance.json` now
  carries a `kind` field (its exact tree-sitter node type), inserted between
  `chunk_type` and `chunk_id`. `spec_version` is now `"2.0"`. Conformance now runs
  over the seven byte-exact sample fixtures in `test/fixture/samples/`. The
  sibling Rust implementation changes in lockstep; the chunk arrays must stay
  byte-identical across both.
- **Module-fallback line count fixed.** The whole-file fallback chunk's
  `end_line` is now `(number of "\n" bytes in the content) + 1` — closing the one
  v1 cross-language divergence so the fallback chunk's id is identical across
  languages (SPEC-V2 §4).
- **Supported-language set changed.** Four languages added (see below); the
  supported set is now the six packs.
- **Store schema** gained a `kind` column; existing v1 stores must be re-indexed.
- **`Chunker.extract_imports` / `Chunker.chunk_file`** now resolve the language
  from the **file path** via the registry (not a language-name argument).

### Added

- **`LanguagePack` architecture.** Each language is one pack under
  `lib/cce/packs/` declaring its extensions, function/class node types, import
  rule, grammar, and a self-test sample. A `PackRegistry` resolves a file to its
  pack by extension and rejects a duplicate-extension registration. The core
  chunker/importer name **no language** — a test (`core_language_guard_test.rb`)
  enforces it.
- **Four new languages** as packs: **Ruby, Rust, TypeScript, C** — joining the
  existing **Python** and **JavaScript** (now packs too). Six total.
- **Per-chunk `kind`** = the exact tree-sitter node type, carried through
  persistence, and surfaced in `search` (`--json` and human output), `stats`
  (a per-`kind` breakdown), the dashboard (recent-searches "Top kind" column),
  and `conformance.json`. `kind` does not affect scoring or `chunk_id`.
- **Three-layer pack validators** (`PackValidator`): structural lint,
  grammar-binding lint with edit-distance "did you mean" node-kind suggestions,
  and a behavioural self-test (min function/class counts, required kinds, and
  exact `extract_imports`). Surfaced via **`cce packs`** / **`cce packs
  --validate`**, a CI test-gate over every pack, and cheap fail-fast startup
  checks.
- **`cce packs [--validate]`** command.
- **Seven byte-exact sample fixtures** under `test/fixture/samples/` — both the
  pack self-tests and the cross-language conformance corpus.
- Documentation: [`SPEC-V2.md`](SPEC-V2.md), a new
  [`docs/adding-a-language.md`](docs/adding-a-language.md) guide, and a
  "Language packs" section + taxonomy + "where this strains" note in
  [`docs/architecture.md`](docs/architecture.md).

### Changed

- Test suite: **163 tests, ~93% line coverage** (SimpleCov), still deterministic
  and hermetic.

## [1.1.0] - 2026-07-05

Dashboard & observability (DASHBOARD-SPEC v1.1). Adds a persisted metrics event
log, a pure aggregator, a `feedback` command, and a local read-only web
dashboard. The core engine (chunking, embedding, retrieval) is unchanged and
`conformance.json` is byte-for-byte identical to 1.0.0.

### Added

- **Persisted metrics event log** at `<store-dir>/metrics.jsonl` (JSON Lines):
  a `search` event on every `cce search`, an `index` event on `cce index`, and a
  `feedback` event on the new `cce feedback` command. Writes are best-effort and
  fail-open — a metrics failure never breaks the command. The clock and id source
  are injected so the behaviour is deterministic under test.
- **Whole-file token persistence:** `cce index` now records each file's whole-file
  `token_count`, so a search's `baseline_tokens` (the "read the whole file"
  counterfactual) is accurate.
- **Pure aggregator** turning the log into totals, two north-stars (token/cost
  **savings** and retrieval **quality**), a daily series, and current-vs-prior
  7-day-window deltas with an improving/degrading/flat direction. It reproduces
  the DASHBOARD-SPEC §4.1 anchor exactly from `test/fixture/metrics_sample.jsonl`.
- **`cce feedback <query-id> --helpful|--not-helpful [--note "..."]`:** marks a
  past search result helpful or not. `cce search` now prints a `query-id:` line
  (and adds `query_id` to `--json`) so results can be rated.
- **`cce dashboard [--dir DIR|--store PATH] [--port N] [--metrics PATH]
  [--no-open]`:** a loopback-only (127.0.0.1), read-only, fully self-contained
  web server (inline CSS/JS, hand-drawn SVG charts, no external network/CDN)
  serving `GET /` (HTML), `GET /api/metrics` (the §4 aggregate JSON), and
  `GET /api/health`.
- Documentation: [`docs/dashboard.md`](docs/dashboard.md) (metrics pipeline,
  event schema, aggregation formulas, and a "where this would strain" note).

### Changed

- `cce search --json` now emits an **object** `{"query_id": ..., "results": [...]}`
  instead of a bare array, to carry the query id (see `docs/DECISIONS.md` D13).
  The `results` array is otherwise unchanged.
- Added a runtime dependency on `webrick` for the loopback dashboard server.
- Test suite: **118 tests, ~93% line coverage** (SimpleCov), still deterministic
  and hermetic (no external network; the metrics clock/id are injected in tests).

## [1.0.0] - 2026-07-05

Initial public release. A clean-room, test-first Ruby implementation of the
Code Context Engine specification ([`SPEC.md`](SPEC.md), SPEC v1.0).

### Added

- `bin/cce` command-line interface with `index`, `search`, `stats`, `bench`, and
  `conformance` commands.
- AST chunking of source files into function/class chunks via tree-sitter
  (`ruby_tree_sitter` + `tree_sitter_language_pack`, Python and JavaScript
  grammars), with a whole-file module fallback.
- Deterministic, model-free `hash` embedder (FNV-1a-64 buckets, L2-normalised,
  256 dimensions) and cosine similarity.
- Optional, opt-in `ollama` embedder over localhost HTTP, behind the same
  interface, with graceful fallback when unreachable.
- Hybrid retrieval pipeline: brute-force cosine vector search, BM25 keyword
  search, Reciprocal Rank Fusion, confidence blending, test/doc path penalty,
  per-file diversity cap, and optional import-graph expansion.
- On-disk persistence in SQLite (chunks, vectors, imports, embedder metadata)
  with idempotent full-rebuild re-indexing.
- Deterministic conformance harness emitting `conformance.json` for
  cross-implementation equivalence with the sibling Rust implementation.
- Benchmark runner producing `docs/BENCHMARKS.md`.
- Documentation: specification, architecture, decisions log, TDD log,
  getting-started and how-to guides.
- Test suite: 84 tests, ~94% line coverage (SimpleCov), deterministic and
  hermetic (no network).

[Unreleased]: https://github.com/davidslv/cce-ruby/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/davidslv/cce-ruby/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/davidslv/cce-ruby/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/davidslv/cce-ruby/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/davidslv/cce-ruby/releases/tag/v1.0.0
