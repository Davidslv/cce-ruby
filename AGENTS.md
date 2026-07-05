# AGENTS.md

Instructions for an AI agent (or any automated contributor) working in this
repository. Humans should read [`CONTRIBUTING.md`](CONTRIBUTING.md); the rules
are the same, framed here for agents.

## What this project is

cce-ruby is a **clean-room, test-first Ruby implementation of
[`SPEC.md`](SPEC.md)** (SPEC v1.0). A sibling Rust implementation is built from
the *identical* spec. The spec is the source of truth for behaviour, and a
`conformance.json` proves the two implementations agree. Treat the spec as
binding.

## The gate that must stay green

```sh
bundle exec rake test
```

- This must pass (0 failures, 0 errors) before you consider any change done.
- Baseline: **118 tests, ~93% line coverage** (SimpleCov). Do not let coverage
  regress. One test is skipped by design (the live Ollama integration test).
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

- Running `bundle exec bin/cce conformance test/fixture` must still produce the
  committed `conformance.json` **byte-for-byte**.
- If your change alters that output, it is a **spec change**, not a bug fix.
  Stop and treat it as such: update [`SPEC.md`](SPEC.md), record the reasoning in
  [`docs/DECISIONS.md`](docs/DECISIONS.md), bump the version, and flag that the
  sibling Rust implementation must change in lockstep. Do not silently commit a
  changed `conformance.json`.
- All scores/comparisons go through `lib/cce/numeric_format.rb`. Do not reorder
  floating-point accumulation or round at new places — determinism depends on
  it.

## Where things live

- `bin/cce` — executable entry point.
- `lib/cce/` — implementation, one concern per file (see [`docs/architecture.md`](docs/architecture.md)).
- `test/` — tests (written first); `test/fixture/` is the normative conformance corpus.
- `lib/cce/metrics*.rb`, `lib/cce/dashboard*.rb` — the v1.1 metrics/observability
  subsystem (event log, recorder, pure aggregator, and the loopback dashboard
  app/page/server). See [`docs/dashboard.md`](docs/dashboard.md).
- `docs/` — [`architecture.md`](docs/architecture.md), [`dashboard.md`](docs/dashboard.md),
  [`DECISIONS.md`](docs/DECISIONS.md), [`TDD.md`](docs/TDD.md), [`BENCHMARKS.md`](docs/BENCHMARKS.md),
  [`getting-started.md`](docs/getting-started.md), [`how-to.md`](docs/how-to.md).
- `SPEC.md` — the authoritative specification; `DASHBOARD-SPEC.md` — the v1.1
  dashboard/observability addendum.

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
- [ ] Docs / `CHANGELOG.md` updated as needed.
- [ ] No network, clock, or randomness added to tests.

## Do not

- Do not run `git init`, create a GitHub repo, or push unless explicitly asked.
- Do not add dependencies casually — runtime deps are pinned in the `Gemfile`
  for a reason. Discuss additions in an issue first.
- Do not add network calls to any path except the existing opt-in, localhost-only
  Ollama embedder.
