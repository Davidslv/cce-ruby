# Code Context Engine (CCE) — Ruby implementation

A local command-line tool that indexes a source-code repository so a program (or
an AI agent) can **search** for the most relevant code snippets instead of
reading whole files. It AST-chunks files with tree-sitter, embeds each chunk,
stores a vector + keyword index on disk, and answers queries with hybrid vector
+ BM25 retrieval — entirely on your machine, with no network calls by default.

> **Provenance.** This is a **clean-room reimplementation, built test-first
> from the specification in [`SPEC.md`](SPEC.md)** as an experiment. A sibling
> implementation in Rust — built from the *identical* spec — lives at
> [davidslv/cce-rust](https://github.com/davidslv/cce-rust). Both are **SPEC
> v1.0** at the core, extended by the **v1.1 dashboard/observability addendum**
> ([`DASHBOARD-SPEC.md`](DASHBOARD-SPEC.md)) — the core engine and its
> `conformance.json` are unchanged. The experiment (and what it says about specs
> as programs) is written up here:
> [The spec was the program](https://davidslv.uk/2026/07/05/the-spec-was-the-program.html).

## Pipeline

```
index a directory
  → walk files → AST-chunk each file into functions/classes (tree-sitter)
  → embed each chunk into a 256-dim vector (deterministic hashing embedder)
  → store vectors + a BM25 keyword index + a small import graph on disk (SQLite)
search a query
  → hybrid retrieve: cosine vector similarity + BM25 + Reciprocal Rank Fusion
  → confidence-score, penalize test/doc paths, enforce per-file diversity
  → optionally expand via the import graph
  → return the top-K ranked chunks
```

## Requirements

- **Ruby 3.2+** (developed on 3.4.7).
- A C toolchain is **not** required at runtime: tree-sitter grammars for Python
  and JavaScript are provided as prebuilt dylibs by the
  `tree_sitter_language_pack` gem and loaded through the `ruby_tree_sitter`
  bindings.

## Quickstart

```sh
# 1. Install dependencies (Ruby >= 3.2 required)
bundle install

# 2. Run the test suite (deterministic, hermetic, no network)
bundle exec rake test

# 3. Index a directory (writes a store under <dir>/.cce/index.db by default)
bundle exec bin/cce index path/to/repo

# 4. Search it (loads the store from a fresh process)
bundle exec bin/cce search "hash the password" --dir path/to/repo --top-k 10
```

> The first `index`/`search`/`conformance` run downloads the Python and
> JavaScript grammar libraries into a local cache (one-time, requires network).
> The default test suite assumes that cache is already warm and performs no
> network I/O.

## Usage

```sh
# Index a directory (writes a store under <dir>/.cce/index.db by default)
bundle exec bin/cce index path/to/repo

# Search (loads the store from a fresh process)
bundle exec bin/cce search "hash the password" --dir path/to/repo --top-k 10
bundle exec bin/cce search "process payment" --dir path/to/repo --json --no-graph

# Corpus statistics
bundle exec bin/cce stats --dir path/to/repo

# Benchmark against a pinned repo, writing docs/BENCHMARKS.md
bundle exec bin/cce bench path/to/flask

# Cross-implementation conformance output
bundle exec bin/cce conformance test/fixture -o conformance.json
```

### Commands

| Command | Purpose |
|---|---|
| `index <dir> [--store PATH] [--embedder hash\|ollama]` | Walk, chunk, embed, persist. |
| `search <query> [--dir DIR \| --store PATH] [--top-k N] [--no-graph] [--json]` | Load store, run retrieval. |
| `stats [--dir DIR \| --store PATH]` | Chunk/file counts, per-language breakdown, avg tokens, store size. |
| `bench <repo-dir> [--queries FILE] [--store PATH]` | Run the benchmark, write `docs/BENCHMARKS.md`. |
| `conformance <fixture-dir> [-o FILE]` | Emit the deterministic `conformance.json`. |
| `feedback <query-id> --helpful\|--not-helpful [--note "…"] [--dir DIR \| --store PATH]` | Rate a past search result (v1.1). |
| `dashboard [--dir DIR \| --store PATH] [--port N] [--no-open]` | Serve the read-only, loopback-only metrics dashboard (v1.1). |

## Embedders

- **`hash` (default):** a deterministic, model-free hashing embedder (FNV-1a
  buckets with a sign bit, L2-normalised). Reproducible across machines and
  languages — this is what conformance and benchmarks use. **No network.**
- **`ollama` (optional, opt-in):** talks to a local
  [Ollama](https://ollama.com/) server (`http://localhost:11434`, model
  `nomic-embed-text`) behind the same interface. This is the **only** code path
  that makes a network call, and only over localhost. Not covered by
  conformance (model-dependent vectors). Falls back with a clear message when
  the server is unreachable.

## Dashboard & observability

Added in **v1.1**. CCE can tell you whether *using it is improving or degrading
your experience over time*, from persisted data, along two north-stars: **token &
cost savings** and **retrieval quality** — each trended, with an
improving/degrading/flat indicator (current 7 days vs the prior 7).

Every `search`, `index`, and `feedback` appends one JSON line to a persisted event
log at `<store-dir>/metrics.jsonl` (best-effort — a metrics failure never breaks
the command). A pure aggregator turns that log into KPIs, daily series, and
windowed deltas, served by a **local, read-only, fully self-contained** web page.

```sh
# 1. Index and search as usual — each search records an event and prints a query-id.
bundle exec bin/cce index path/to/repo
bundle exec bin/cce search "hash the password" --dir path/to/repo
#   → …results…
#   → query-id: 3f9a1c2b7e04  ·  rate with: cce feedback 3f9a1c2b7e04 --helpful|--not-helpful

# 2. Rate a result you found helpful (or not).
bundle exec bin/cce feedback 3f9a1c2b7e04 --helpful --dir path/to/repo

# 3. Open the dashboard (loopback-only; prints the URL, Ctrl-C to stop).
bundle exec bin/cce dashboard --dir path/to/repo
#   → CCE dashboard (read-only, loopback-only) at http://127.0.0.1:8787/
```

The dashboard inlines all CSS/JS and draws its own SVG charts — **no external
network, CDN, or remote fonts/scripts** — consistent with CCE's offline posture.
It also exposes `GET /api/metrics` (the aggregate JSON) and `GET /api/health`.
See [`docs/dashboard.md`](docs/dashboard.md) for the pipeline, event schema, and
aggregation formulas.

## Testing

```sh
bundle exec rake test
```

The suite is deterministic and hermetic (no external network): **118 tests, ~93%
line coverage** (SimpleCov; 1 skip is the live Ollama integration test, excluded
from the default suite). The metrics subsystem's clock and id source are injected
so its tests are deterministic despite the feature being time-based. See
[`docs/TDD.md`](docs/TDD.md) for the red→green log, the exact test count, and the
coverage breakdown.

## Documentation

| Doc | What it covers |
|---|---|
| [`SPEC.md`](SPEC.md) | The authoritative specification (SPEC v1.0). The source of truth for behaviour. |
| [`docs/getting-started.md`](docs/getting-started.md) | Newcomer path: install → first successful index + search. |
| [`docs/how-to.md`](docs/how-to.md) | Task recipes: index, search, benchmark, conformance, switch to Ollama. |
| [`docs/architecture.md`](docs/architecture.md) | Design goals, component model, rationale, and where the design would strain. |
| [`docs/dashboard.md`](docs/dashboard.md) | The v1.1 metrics pipeline, event schema, aggregation formulas, and strain points. |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Every spec ambiguity resolved, with rationale. |
| [`docs/TDD.md`](docs/TDD.md) | The test-first build log, test count, and coverage. |
| [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md) | Headline retrieval-quality and latency numbers. |
| [`docs/TIMING.md`](docs/TIMING.md) | Wall-clock time for the clean-room build. |

## Layout

```
bin/cce                 # executable entry point
lib/cce/                # implementation, one concern per file
  config.rb             # normative constants
  numeric_format.rb     # rounding, fixed-6 formatting, canonical sort
  tokenizer.rb          # shared byte tokenizer
  hashing.rb            # FNV-1a-64
  embedder.rb           # hash embedder + cosine
  ollama_embedder.rb    # optional Ollama backend
  grammars.rb           # tree-sitter grammar loading
  chunker.rb            # AST chunking + import extraction + chunk id
  walker.rb             # file walking + ignore rules
  vector_store.rb       # brute-force cosine search
  keyword_store.rb      # BM25 index
  graph_store.rb        # import graph
  retriever.rb          # the hybrid pipeline
  store.rb              # SQLite persistence
  indexer.rb            # index orchestration + retriever loading
  conformance.rb        # conformance harness
  bench.rb              # benchmark runner
  metrics.rb            # metrics constants + injectable clock/id sources (v1.1)
  metrics_event_log.rb  # append/read the JSONL event log (v1.1)
  metrics_recorder.rb   # build search/index/feedback events (v1.1)
  metrics_aggregator.rb # pure aggregate: totals, north-stars, series (v1.1)
  dashboard_page.rb     # self-contained dashboard HTML/CSS/JS (v1.1)
  dashboard_app.rb      # read-only request router (v1.1)
  dashboard_server.rb   # loopback WEBrick server (v1.1)
  cli.rb                # command-line dispatch
test/                   # tests, written first
test/fixture/           # the normative conformance fixture corpus
docs/                   # architecture, DECISIONS, TDD, BENCHMARKS, TIMING, guides
```

## Contributing

Contributions are welcome. Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) and
[`AGENTS.md`](AGENTS.md) first — CCE is developed test-first and every change
must keep `bundle exec rake test` green and spec conformance unchanged. See
[`GOVERNANCE.md`](GOVERNANCE.md) for how decisions are made (solo, BDFL model)
and [`SUPPORT.md`](SUPPORT.md) for where to get help.

## License

[MIT](LICENSE) © 2026 David Silva.
