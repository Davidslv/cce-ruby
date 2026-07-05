# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/davidslv/cce-ruby/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/davidslv/cce-ruby/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/davidslv/cce-ruby/releases/tag/v1.0.0
