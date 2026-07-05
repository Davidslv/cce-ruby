# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/davidslv/cce-ruby/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/davidslv/cce-ruby/releases/tag/v1.0.0
