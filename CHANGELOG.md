# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/davidslv/cce-ruby/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/davidslv/cce-ruby/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/davidslv/cce-ruby/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/davidslv/cce-ruby/releases/tag/v1.0.0
