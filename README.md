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
> ([`DASHBOARD-SPEC.md`](DASHBOARD-SPEC.md)) and the **v2.0 pluggable
> language-pack evolution** ([`SPEC-V2.md`](SPEC-V2.md)). The experiment (and what
> it says about specs as programs) is written up here:
> [The spec was the program](https://davidslv.uk/2026/07/05/the-spec-was-the-program.html).

> **v2.0 (breaking).** Language support is now a **pluggable pack architecture**:
> the core engine holds zero language-specific knowledge and resolves each file to
> a `LanguagePack` through a registry. Six languages ship — **Ruby, Rust,
> TypeScript, C, Python, JavaScript** — each a self-contained pack validated by a
> three-layer safety rail (`cce packs --validate`). Every chunk now carries a
> `kind` (its exact tree-sitter node type), and the `conformance.json` chunk shape
> gained that field. See [`docs/adding-a-language.md`](docs/adding-a-language.md).

## Walkthrough

![CCE walkthrough — language packs, index, validate, search, stats](docs/walkthrough.gif)

▶ **Interactive version:** open [`docs/presentation/index.html`](docs/presentation/index.html)
in a browser — a self-contained, autoplaying terminal cast (no dependencies, no network).

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
- A C toolchain is **not** required at runtime: the tree-sitter grammars for all
  six supported languages (Ruby, Rust, TypeScript, C, Python, JavaScript) are
  provided as prebuilt dylibs by the `tree_sitter_language_pack` gem and loaded
  through the `ruby_tree_sitter` bindings.

## Supported languages

Each language is one **pack** (`lib/cce/packs/<name>.rb`): a small, self-contained
unit that declares its extensions, its function/class node types, its import rule,
and a self-test sample. Adding a language is *add one pack file + register it + it
passes `cce packs --validate`* — no core edits.

| Pack | Extensions | Chunks (function / class) | Imports from |
|---|---|---|---|
| `ruby` | `.rb` | methods, singleton methods / classes, modules | `require`, `require_relative` |
| `rust` | `.rs` | `fn` items / struct·enum·trait·impl·union items | `use` (first path segment) |
| `typescript` | `.ts`, `.tsx` | functions, methods, arrow/function exprs / class·interface·enum decls | `import … from "x"` |
| `c` | `.c`, `.h` | function definitions / struct·union·enum specifiers | `#include <…>` / `"…"` |
| `python` | `.py` | function defs / class defs | `import`, `from … import` |
| `javascript` | `.js`, `.jsx`, `.mjs`, `.cjs` | functions, methods, arrow/function exprs / class decls | `import … from "x"` |

Files with no matching pack fall back to a single whole-file `module` chunk.
Run `cce packs` to list what is registered, or `cce packs --validate` to run the
structural, grammar-binding, and behavioural validators over every pack.

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

> The first `index`/`search`/`conformance` run downloads the six grammar
> libraries into a local cache (one-time, requires network). The default test
> suite assumes that cache is already warm and performs no network I/O.

## Usage

```sh
# Index a directory (writes a store under <dir>/.cce/index.db by default).
# Secret protection is ON by default: sensitive files are skipped and inline
# secrets are redacted before anything is stored (see "Secret protection" below).
bundle exec bin/cce index path/to/repo

# Opt out of secret protection for a single run (not recommended)
bundle exec bin/cce index path/to/repo --allow-secrets

# Search (loads the store from a fresh process)
bundle exec bin/cce search "hash the password" --dir path/to/repo --top-k 10
bundle exec bin/cce search "process payment" --dir path/to/repo --json --no-graph

# Corpus statistics
bundle exec bin/cce stats --dir path/to/repo

# Benchmark against a pinned repo, writing docs/BENCHMARKS.md
bundle exec bin/cce bench path/to/sinatra

# List / validate the language packs
bundle exec bin/cce packs
bundle exec bin/cce packs --validate

# Cross-implementation conformance output (over the seven sample fixtures)
bundle exec bin/cce conformance test/fixture/samples -o conformance.json
```

### Commands

| Command | Purpose |
|---|---|
| `index <dir> [--store PATH] [--embedder hash\|ollama] [--allow-secrets]` | Walk, chunk, embed, persist. Secret-safe by default; `--allow-secrets` opts out. |
| `search <query> [--dir DIR \| --store PATH] [--top-k N] [--no-graph] [--json]` | Load store, run retrieval. |
| `stats [--dir DIR \| --store PATH]` | Chunk/file counts, per-language and per-`kind` breakdown, avg tokens, store size. |
| `bench <repo-dir> [--queries FILE] [--store PATH]` | Run the benchmark, write `docs/BENCHMARKS.md`. |
| `packs [--validate]` | List registered language packs, or run the three-layer validators over every pack. |
| `conformance <fixture-dir> [-o FILE]` | Emit the deterministic `conformance.json` (chunks include `kind`). |
| `feedback <query-id> --helpful\|--not-helpful [--note "…"] [--dir DIR \| --store PATH]` | Rate a past search result (v1.1). |
| `dashboard [--dir DIR \| --store PATH] [--port N] [--no-open]` | Serve the read-only, loopback-only metrics dashboard (v1.1). |
| `workspace init [<dir>] [--force]` | Detect members → write `.cce/workspace.yml` (v2.2). |
| `workspace list [<dir>]` | Print members + cross-member edges (v2.2). |
| `index --workspace [<dir>]` | Index each member into its own store + build the graph (v2.2). |
| `search <query> --workspace [<dir>] [--package a,b] […]` | Federated search over the members' union (v2.2). |
| `stats --workspace [<dir>]` | Per-member metrics + totals + edges (v2.2). |
| `dashboard --workspace [<dir>]` | Federated roll-up dashboard with a per-package breakdown (v2.2). |

## Secret & sensitive-file protection

Indexing is **secret-safe by default** (two layers, both on unless you pass
`--allow-secrets`):

- **Layer 1 — sensitive files are never read.** Before a file is opened, its
  name is checked against a fixed table: sensitive extensions (`pem`, `key`,
  `p12`, `pfx`, `keystore`, `jks`, `ppk`, `der`, `asc`), exact credential
  basenames (`credentials.*`, `secrets.*`, `.netrc`, `.pgpass`, `.htpasswd`,
  `.dockercfg`, `kubeconfig`, `id_rsa`/`id_dsa`/`id_ecdsa`/`id_ed25519`), and the
  dotenv rule (`.env` and `.env.*` are skipped — but safe templates ending in
  `.example`, `.sample`, `.template`, or `.dist` are indexed normally). Skipped
  files are reported separately as `sensitive skipped` in the `index` summary and
  never enter the store.
- **Layer 2 — inline secrets are redacted before storage.** Each indexed file's
  content is scrubbed for high-confidence secrets (AWS/GitHub/Slack/Stripe/
  OpenAI/Anthropic/Google keys, private-key blocks, JWTs, and a guarded generic
  `key = value` assignment) and each match is replaced with `[REDACTED:<LABEL>]`.
  The **redacted** text is what gets chunked, embedded, and stored, so the local
  store never contains the secret. Documentation placeholders such as
  `API_KEY="your-api-key-here"` are left intact by design.

`--allow-secrets` disables **both** layers for that run and prints a warning; use
it only when you deliberately need to index credential material. Even so, the
store is always local-only (`.cce/…` on disk) — see `SECURITY.md`.

## Workspaces / ecosystems

A **workspace** lets CCE treat several related codebases under one root — say a
Rails `app`, a `billing` engine, and a `web` frontend — as one searchable whole,
while **each member keeps its own isolated store**. Nothing is stored centrally
except two small metadata files at the root (`.cce/workspace.yml` and
`.cce/workspace-graph.json`).

```text
myproduct/
  app/               Gemfile (gem "billing"), config/application.rb, app/models/…
  engines/
    billing/         billing.gemspec (name = "billing"), lib/billing.rb
  web/               package.json (name = "web"), tsconfig.json, src/index.ts
```

```sh
# 1. Detect members and write a reviewable manifest at <root>/.cce/workspace.yml
bundle exec bin/cce workspace init myproduct
#   app     [rails-app]      app             (package: app)
#   billing [ruby-engine]    engines/billing (package: billing)
#   web     [typescript]     web             (package: web)

# 2. See the members and the cross-member dependency edges
bundle exec bin/cce workspace list myproduct
#   app -> billing (gemfile)     ← app's Gemfile declares gem "billing"

# 3. Index every member into its OWN <member>/.cce/ + build the graph
bundle exec bin/cce index --workspace myproduct

# 4. Federated search across the whole ecosystem (results tagged by member)
bundle exec bin/cce search "charge amount" --workspace myproduct
#   0.83…  app · app/models/charge.rb:1-5 (class/class)
#   0.79…  billing · lib/billing.rb:1-5 (class/module)

#    …scope to named members, and drop the graph hop, as you like
bundle exec bin/cce search "charge" --workspace myproduct --package app,billing --no-graph --json

# 5. Ecosystem stats and a federated dashboard (roll-up + per-package breakdown)
bundle exec bin/cce stats     --workspace myproduct
bundle exec bin/cce dashboard --workspace myproduct
```

**How it works.** Members are auto-detected by marker (`*.gemspec` → Ruby gem or
engine; `Gemfile` + `config/application.rb` → Rails app; `package.json` →
TypeScript/JavaScript) and never nest. Each member is indexed by the *normal*
pipeline, so a member's store is **byte-identical to indexing it standalone** —
language packs and secret scrubbing apply per member. A federated search is
defined to equal a single standard retrieval over the **union** of the in-scope
members' chunks, so it returns the same ranking as one index built over them.
Cross-member **dependency edges** (read from `Gemfile` / `*.gemspec` /
`package.json`) let a top result in one member expand into the members it depends
on. See [`docs/workspace.md`](docs/workspace.md) for the full model.

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

![CCE dashboard — token & cost savings and retrieval quality, trended](docs/dashboard.png)

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

The suite is deterministic and hermetic (no external network): **256 tests, ~94%
line coverage** (SimpleCov; 1 skip is the live Ollama integration test, excluded
from the default suite). The metrics subsystem's clock and id source are injected
so its tests are deterministic despite the feature being time-based. See
[`docs/TDD.md`](docs/TDD.md) for the red→green log, the exact test count, and the
coverage breakdown.

## Documentation

| Doc | What it covers |
|---|---|
| [`SPEC.md`](SPEC.md) | The authoritative specification (SPEC v1.0). The source of truth for behaviour. |
| [`SPEC-V2.md`](SPEC-V2.md) | The v2.0 evolution spec: pluggable language packs, `kind`, validators, conformance v2. |
| [`SPEC-V2.1.md`](SPEC-V2.1.md) | The v2.1 evolution spec: secret & sensitive-file protection. |
| [`SPEC-V2.2.md`](SPEC-V2.2.md) | The v2.2 evolution spec: workspaces / multi-codebase ecosystems. |
| [`docs/workspace.md`](docs/workspace.md) | The workspace model, manifest format, detection rules, federation semantics, and strain points. |
| [`docs/getting-started.md`](docs/getting-started.md) | Newcomer path: install → first successful index + search. |
| [`docs/how-to.md`](docs/how-to.md) | Task recipes: index, search, benchmark, packs, conformance, switch to Ollama. |
| [`docs/adding-a-language.md`](docs/adding-a-language.md) | Step-by-step guide to adding a language pack, with a worked example. |
| [`docs/architecture.md`](docs/architecture.md) | Design goals, component model, the language-pack model, and where the design would strain. |
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
  grammars.rb           # tree-sitter grammar loading (language-agnostic)
  chunker.rb            # AST chunking + import extraction + chunk id (language-blind)
  pack_registry.rb      # resolves a file to its LanguagePack (v2.0)
  pack_validator.rb     # three-layer pack validators (v2.0)
  packs.rb              # builds the default registry of shipped packs (v2.0)
  packs/                # one file per language: python, javascript, ruby, rust, typescript, c (v2.0)
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
  workspace.rb          # workspace namespace + constants (v2.2)
  workspace/            # detector, manifest, dependencies, graph, indexer,
                        #   federation, stats, dashboard (v2.2)
  cli.rb                # command-line dispatch
test/                   # tests, written first
test/fixture/samples/   # the seven byte-exact sample fixtures (pack self-tests + conformance corpus)
test/fixture/workspace/ # the workspace fixture: app / billing / web (v2.2)
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
