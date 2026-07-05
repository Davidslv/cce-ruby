# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.4.1] - 2026-07-05

The **closing task of the v2.4 milestone**: a dashboard refresh that surfaces the
capabilities shipped since v1.1 (workspaces, Sync, MCP, secret-scrubbing), plus a
verified, gapless documentation sweep and a mandatory offline-first verification.
Additive patch release — the CLI, the single-repo `conformance.json`, and the
cross-engine **sync golden checksum** (`581cbd0f…`,
`SYNC_FORMAT_VERSION = "2.3"`) are all byte-for-byte unchanged. Old metrics logs
still parse: every new event field is optional and degrades gracefully.

### Added

- **Metrics schema (additive).** `search` events now carry `source` (`"cli"` for the
  human CLI path, `"mcp"` for the agent/`context_search` path) and an optional
  `package` (workspace filter). `index` events now carry `sha` (the VCS commit
  indexed/pulled), `source` (`"local"` for `cce index`, `"sync-pull"` for an index
  installed by `cce sync pull`), and `sensitive_skipped` (files the secret-safe
  walker refused to read). Every field is optional/defaulted so pre-v2.4 logs parse
  unchanged and absent fields degrade gracefully in the aggregator.
- **Dashboard panels — the single cross-engine canonical `/api/metrics` contract.**
  - `totals.mean_top_score` — mean rank-1 score over the log's non-empty searches.
  - `by_source` — agent-vs-human usage: `{ cli:{searches,tokens_saved,
    mean_savings_ratio,mean_top_score}, mcp:{…} }`. Searches with `source=="mcp"`
    count as agent; everything else (incl. pre-v2.4/absent) as `cli`.
  - `index_freshness` — index freshness / sync status computed **offline** from
    index events: `{ indexes, source, sha, indexed_ts }`. `remote_latest`/
    `behind_remote` stay in `cce sync status` and the MCP `index_status` tool (an
    explicit network action), keeping the dashboard offline.
  - `secret_safety` — `{ sensitive_skipped, index_runs }`, summed/counted across
    index events.
  - Workspace `by_package` — a sorted **array** of `{ package, searches,
    tokens_saved, mean_savings_ratio, mean_top_score }` (per-member retrieval
    quality added).
  - The self-contained dashboard page renders all four (agent-vs-human, index
    freshness · sync · secret-safety, per-member breakdown), staying loopback-only,
    read-only, and self-contained.
- **Documentation sweep.** Every doc audited and brought current to shipped v2.4
  behaviour, with copy-pasteable, output-backed examples for single-repo · workspace
  · Sync · MCP · dashboard; macOS **and** Ubuntu setup with explicit prerequisites
  (toolchain, C compiler, git, git-LFS); a Best-Practices section for Sync + MCP; and
  a dedicated, **verified offline-first** section.
- **`docs/VERIFIED.md`** records both an **online** and an **offline** cold-start
  transcript (real captured runs) proving `index`, `search`, `stats`, `dashboard`,
  `workspace`, and `cce mcp` (serving the local index) all work with no network and
  no remote.

## [2.4.0] - 2026-07-05

CCE MCP (SPEC-MCP) — a **Model Context Protocol server** so an agent (Claude Code,
Cursor, …) calls CCE as a **first-class tool it auto-invokes**, plus `cce init` for
plug-and-play editor wiring. This closes the one gap between clean-room CCE and the
original: agent integration. Additive minor release — the CLI and the single-repo
`conformance.json` are byte-for-byte unchanged, and the engine stays offline-first.
The Ruby and Rust engines expose the **same tool names, input schemas, and output
shape** (the cross-language contract).

### Added

- **`cce mcp` — an MCP server over stdio (JSON-RPC 2.0).** `CCE::MCP::Server`
  hand-rolls line-delimited JSON-RPC 2.0 (no new dependency): handshake
  `initialize` → `{ protocolVersion, capabilities:{tools:{}}, serverInfo:{name:"cce",
  version} }`; `notifications/initialized`; `tools/list`; `tools/call`; `ping`. The
  MCP protocol revision is pinned to **`2025-06-18`**. Read-only and offline; a
  malformed message becomes a JSON-RPC error and a tool raise an `isError` result —
  the server never crashes.
- **Three tools with exact, cross-language schemas (`CCE::MCP::Tools`).**
  `context_search` (`{ query, top_k=8, package?, no_graph?, max_tokens? }`) — the
  "PREFERRED over Read/Grep" tool; returns ranked chunks (`file:line` + kind) + a
  `query_id`, and **logs a `search` event** to `.cce/metrics.jsonl` so the dashboard
  sees agent usage. `index_status` (`{}`) — counts, per-language/kind, store path,
  freshness. `record_feedback` (`{ query_id, helpful, note? }`) — appends a
  `feedback` event.
- **`CCE::MCP::Context`** — resolves the store like the CLI (`--dir`/`--store`/cwd,
  `--workspace`), stays read-only, and handles a missing index with a friendly
  "run `cce index`" message instead of erroring.
- **`cce init [<dir>] [--agent claude] [--remote <sync-url>] [--force]`
  (`CCE::MCP::Init`).** Ensures an index (via `cce sync pull --latest` when
  `--remote`/configured, else `cce index` / `cce index --workspace`), then
  idempotently writes/merges `.mcp.json` (`{ mcpServers:{ cce:{ command:"cce",
  args:["mcp","--dir","."] } } }`) and a bounded `CLAUDE.md` block steering the agent
  to prefer `context_search`. Prints next steps.
- **CCE MCP × CCE Sync (soft dependency).** On startup, when a sync remote is
  configured and `sync.auto_pull` is on, `cce mcp` does a best-effort
  `sync pull --latest` to warm the local index (offline-safe — never blocks or
  errors). `index_status` reports the index source (local vs pulled), its `sha`, and
  whether it is behind the remote. MCP works fully with **no** Sync configured;
  `sync.auto_pull` reuses the existing `sync.*` config keys.
- **Docs & verification.** New [`docs/mcp.md`](docs/mcp.md); a README "Use it with
  Claude Code (MCP)" section; a cold-start MCP transcript in
  [`docs/VERIFIED.md`](docs/VERIFIED.md) (every documented command run verbatim).

### Changed

- **Sync artifact FORMAT window pinned to `2.3`.** The content-address `<cce_ver>`
  and the artifact manifest `cce_version` track the interchange **format**, not the
  software version. CCE MCP is purely additive and does not change the sync format,
  so the window stays `2.3` — existing caches remain valid and the cross-language
  golden checksum is unchanged (`CCE::Sync::SYNC_FORMAT_VERSION`; see DECISIONS
  D-MCP-2).
- 40 new tests (server, context, init, CLI); suite **356 runs**, line coverage
  **94.34%**; `conformance.json` unchanged.

## [2.3.0] - 2026-07-05

CCE Sync (SPEC-SYNC) — an optional, **offline-first, content-addressed cache** for
code-context indexes, layered over the local-first core. *git remotes for the
index*: your local `.cce/` stays authoritative, and a git-backed remote is a cache
you push to and pull from. Because indexing is deterministic, the cache for
`repo@sha` (hash embedder) is **byte-identical** across people and across the
Ruby/Rust engines. This is an additive minor release: absent a configured remote
every command behaves exactly as before, and the single-repo `conformance.json` is
byte-for-byte unchanged.

### Added

- **Portable interchange artifact (SPEC-SYNC §2, reconciled canonical format).**
  `CCE::Sync::Artifact` exports a store to the single canonical, byte-exact stream
  both engines reconciled on: a manifest line (keys `cce_version`, `checksum`,
  `chunk_count`, `embedder`, `file_tokens`, `pack_set_id`, `repo_id`, `sha`) → one
  compact sorted-key JSON object per chunk (keys incl. `id` and an explicit
  `language`), sorted by `(file_path, start_line, id)` → a graph line
  `{"edges":[…],"nodes":[…]}`; LF after every line. **Embeddings are standard
  padded base64 of 256 little-endian IEEE-754 `f64` bytes** (not decimals), so
  vectors are bit-identical across languages. No provenance is stored, so the file
  is reproducible; `checksum` is the lowercase-hex SHA-256 over the entire stream
  serialized with `checksum:""` — the value the two engines diff to prove
  interoperability. Import round-trips losslessly (chunk fields, vectors,
  `file_tokens`, and the import graph).
- **Content address (§3).** `CCE::Sync::ContentAddress` keys a cache at
  `<embedder>/<cce_ver>/<repo_id>/<sha>.cce`, with `repo_id` derived from the git
  origin or overridden via `--repo-id`.
- **Git remote backend (§4).** `CCE::Sync::GitRemote` implements the `SyncRemote`
  interface over a working clone under `~/.cce/sync/<remote-id>/`:
  `put`/`get`/`has`/`list`/`latest`, with **fetch-rebase-retry** on a concurrent
  push race and **git-LFS** for `*.cce` (`.gitattributes` written by
  `cce sync init`; `--no-lfs` for plain git).
- **CLI (§5).** `cce sync init | push | pull | status | verify`, each
  `--workspace`-aware (iterating members, keyed by `repo_id__<package>@sha`).
  `push` refuses a dirty working tree and a non-hash index; `pull` validates the
  checksum and will not silently replace a different `sha` without `--force`;
  `verify` re-indexes locally and rebuild-compares the checksum.
- **Config (§8).** `sync.*` keys (`remote`, `lfs`, `repo_id`, `auto_pull`,
  `retention`) in a global `~/.cce/config.yml` merged under a per-project
  `.cce/config`. All optional; absent ⇒ pure local CCE.
- **Docs.** A README *CCE Sync* section with a real captured walkthrough and
  macOS/Ubuntu install steps, [`docs/sync.md`](docs/sync.md) (model, artifact
  format, content address, permissions, a GitHub Actions CI recipe,
  troubleshooting), and a verified cold-start transcript in
  [`docs/VERIFIED.md`](docs/VERIFIED.md).

### Guarantees

- **Offline-first (§9).** No remote ⇒ unchanged behaviour; an unreachable remote
  fails gracefully and never touches the local store; `pull` never clobbers a
  newer local index for a different `sha` without `--force`.
- Only the **hash** embedder is shareable; Ollama/semantic indexes are local-only
  and refused by `push`.

### Changed

- Version bumped to **2.3.0** (`lib/cce.rb`, `CITATION.cff`).
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
