# AGENTS.md

Instructions for an AI agent (or any automated contributor) working in this
repository. Humans should read [`CONTRIBUTING.md`](CONTRIBUTING.md); the rules
are the same, framed here for agents.

## What this project is

cce-ruby is a **clean-room, test-first Ruby implementation of
[`SPEC.md`](SPEC.md)** (SPEC v1.0), extended cumulatively by the v1.1 dashboard
addendum ([`DASHBOARD-SPEC.md`](DASHBOARD-SPEC.md)), v2.0 pluggable language packs
([`SPEC-V2.md`](SPEC-V2.md)), v2.1 secret-scrubbing ([`SPEC-V2.1.md`](SPEC-V2.1.md)),
v2.2 workspaces ([`SPEC-V2.2.md`](SPEC-V2.2.md)), v2.3 CCE Sync
([`SPEC-SYNC.md`](SPEC-SYNC.md)), and v2.4 CCE MCP ([`SPEC-MCP.md`](SPEC-MCP.md)).
The current release is **v2.4.1** (a dashboard refresh + verified offline-first
docs sweep). A sibling Rust implementation is built from the *identical* specs. The
spec is the source of truth for behaviour, and a `conformance.json` proves the two
implementations agree. Treat the spec as binding.

Two invariants that must NOT move on a version bump: the single-repo
`conformance.json` stays byte-identical, and the cross-engine sync golden
(`581cbd0f…`, `SYNC_FORMAT_VERSION = "2.3"` in `lib/cce/sync.rb`) is decoupled from
`CCE::VERSION` — never let an app-version bump change either.

### Language packs (v2.0) — the rule that keeps the core language-blind

Language support is a **pluggable pack architecture**. Each language is one
`LanguagePack` under `lib/cce/packs/`; the core resolves files through
`PackRegistry` and holds **zero** language-specific knowledge.

- **Never name a language (or an extension literal) in the core** —
  `lib/cce/chunker.rb`, `lib/cce/indexer.rb`, `lib/cce/pack_registry.rb`. A test
  (`test/core_language_guard_test.rb`) greps for this and will fail the build.
  Language knowledge and its comments live **only inside packs**.
- **Adding a language = add one pack file + register it in `lib/cce/packs.rb` +
  make `cce packs --validate` pass.** No core edits. See
  [`docs/adding-a-language.md`](docs/adding-a-language.md).
- Every pack must pass all three validator layers (`test/pack_validator_test.rb`
  is the CI gate over every registered pack). Get node-type spellings from the
  grammar, not from memory — the grammar-binding lint suggests the nearest kind.

## The gate that must stay green

```sh
bundle exec rake test
```

- This must pass (0 failures, 0 errors) before you consider any change done.
- Baseline: **372 tests, ~94.8% line coverage** (SimpleCov; ≥ 93% required). Do not
  let coverage regress. One test is skipped by design (the live Ollama integration test).
- The suite is deterministic and hermetic — **no external network, no real clock,
  no randomness in assertions**. Do not introduce any of these into tests.
- **Exception (v1.1):** the metrics/dashboard subsystem is the ONE place CCE uses
  wall-clock time and randomness (`ts`/`id`/`generated_ts`). It is made testable
  by **injecting** the clock and id source (`CCE::Metrics::FixedClock`,
  `SequenceIdSource`, …) and by keeping the aggregator a **pure** function of
  `(events, now, price)`. Tests must inject those, not read the real clock, and
  the dashboard's HTTP tests bind an **ephemeral loopback port** (no real
  network). The §4.1 aggregator anchor
  (`test/metrics_aggregator_test.rb`) is a cross-language equivalence gate — keep
  it exact.

## Test discipline (TDD)

- **Write the test first.** Add or change a failing test that pins the intended
  behaviour, then write the minimum code to pass it, then refactor with the
  suite green. See [`docs/TDD.md`](docs/TDD.md) for the established style.
- **Every code change ships with tests.** No behaviour change without a test
  that would fail without it.
- Prefer small, pure, injectable units — mirror the existing one-concern-per-file
  structure under `lib/cce/`.

## Spec conformance must not drift

This is the rule that overrides convenience:

- Running `bundle exec bin/cce conformance test/fixture/samples` must still
  produce the committed `conformance.json` **byte-for-byte** (v2 chunks carry
  `kind`; the sample fixtures are byte-identical across both implementations).
- If your change alters that output, it is a **spec change**, not a bug fix.
  Stop and treat it as such: update the spec, record the reasoning in
  [`docs/DECISIONS.md`](docs/DECISIONS.md), bump the version, and flag that the
  sibling Rust implementation must change in lockstep. Do not silently commit a
  changed `conformance.json`.
- All scores/comparisons go through `lib/cce/numeric_format.rb`. Do not reorder
  floating-point accumulation or round at new places — determinism depends on
  it.

## Where things live

- `bin/cce` — executable entry point.
- `lib/cce/` — implementation, one concern per file (see [`docs/architecture.md`](docs/architecture.md)).
- `lib/cce/packs/` — one `LanguagePack` per language; `lib/cce/pack_registry.rb`,
  `lib/cce/pack_validator.rb`, `lib/cce/packs.rb` — the v2.0 pack machinery.
- `test/` — tests (written first); `test/fixture/samples/` holds the seven
  byte-exact sample fixtures (pack self-tests + the conformance corpus).
- `lib/cce/metrics*.rb`, `lib/cce/dashboard*.rb` — the v1.1 metrics/observability
  subsystem (event log, recorder, pure aggregator, and the loopback dashboard
  app/page/server). See [`docs/dashboard.md`](docs/dashboard.md).
- `lib/cce/sync*.rb`, `lib/cce/sync/` — the v2.3 offline-first, content-addressed
  sync cache. See [`docs/sync.md`](docs/sync.md).
- `lib/cce/mcp.rb`, `lib/cce/mcp/` — the v2.4 MCP subsystem: `server.rb`
  (JSON-RPC 2.0 over stdio, pinned protocol version), `tools.rb` (the three
  cross-language tools), `context.rb` (read-only store resolution + metrics + sync
  warm-up), `init.rb` (`cce init`). See [`docs/mcp.md`](docs/mcp.md). Keep the tool
  names/schemas/output **identical to the Rust sibling** — that is the contract.
- `docs/` — [`architecture.md`](docs/architecture.md), [`dashboard.md`](docs/dashboard.md),
  [`DECISIONS.md`](docs/DECISIONS.md), [`TDD.md`](docs/TDD.md), [`BENCHMARKS.md`](docs/BENCHMARKS.md),
  [`getting-started.md`](docs/getting-started.md), [`how-to.md`](docs/how-to.md),
  [`sync.md`](docs/sync.md), [`mcp.md`](docs/mcp.md), [`VERIFIED.md`](docs/VERIFIED.md).
- `SPEC.md` — the authoritative specification; `DASHBOARD-SPEC.md` — the v1.1
  dashboard/observability addendum; `SPEC-V2.md` — the v2.0 language-pack evolution;
  `SPEC-SYNC.md` — the v2.3 sync design; `SPEC-MCP.md` — the v2.4 MCP design.

## Commit and PR conventions

- Focused commits, imperative mood, ideally a
  [Conventional Commits](https://www.conventionalcommits.org/) prefix
  (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`).
- Reference the issue (`Closes #NN`). For non-trivial changes, an issue should
  exist first.
- Open PRs against `main` and fill in the pull-request template, including the
  quality-gate checklist.
- Add a line to the `Unreleased` section of [`CHANGELOG.md`](CHANGELOG.md) for
  any user-visible change.
- Update the relevant `docs/` file when behaviour, flags, or architecture change.

## Definition of done (checklist)

- [ ] `bundle exec rake test` is green; coverage not regressed.
- [ ] New/changed behaviour covered by tests, written test-first.
- [ ] `conformance.json` unchanged (or an intentional, documented spec revision).
- [ ] `cce packs --validate` passes; no language named in the core (the guard test is green).
- [ ] Docs / `CHANGELOG.md` updated as needed.
- [ ] No network, clock, or randomness added to tests.

## Do not

- Do not run `git init`, create a GitHub repo, or push unless explicitly asked.
- Do not add dependencies casually — runtime deps are pinned in the `Gemfile`
  for a reason. Discuss additions in an issue first.
- Do not add network calls to any path except the three that already have them:
  the opt-in, localhost-only Ollama embedder, and `cce sync push`/`pull` (git
  transport to a configured remote). `index`/`search`/`stats`/`dashboard`/
  `workspace`/`mcp` are offline and must stay that way; the dashboard binds
  loopback only. The offline-first guarantee is verified in
  [`docs/VERIFIED.md`](docs/VERIFIED.md) — keep it true.
