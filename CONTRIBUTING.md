# Contributing to cce-ruby

Thanks for your interest in the Code Context Engine (Ruby implementation). This
project is a **clean-room, test-first implementation of [`SPEC.md`](SPEC.md)**,
so the contribution rules are stricter than most: the spec is the source of
truth, and behaviour changes are spec changes.

## Before you start

- For anything larger than a typo or an obvious bug fix, **open an issue first**
  so we can agree on the approach before you write code. This is a solo,
  best-effort project (see [`GOVERNANCE.md`](GOVERNANCE.md) and
  [`SUPPORT.md`](SUPPORT.md)); an early conversation saves wasted work.
- Read [`AGENTS.md`](AGENTS.md) — it captures the same working discipline in a
  form suitable for both humans and AI agents.

## Development setup

Requirements: **Ruby >= 3.2** (developed on 3.4.7) and Bundler.

```sh
git clone https://github.com/davidslv/cce-ruby.git
cd cce-ruby
bundle install
```

### System dependencies

Runtime chunking uses tree-sitter through the `ruby_tree_sitter` gem, with
prebuilt grammar dylibs for all six supported languages (Ruby, Rust, TypeScript,
C, Python, JavaScript) supplied by `tree_sitter_language_pack`. Each language is a
self-contained pack under `lib/cce/packs/` — see
[`docs/adding-a-language.md`](docs/adding-a-language.md). On most systems
`bundle install` is enough. On a
clean Linux box (including CI) you may need a C toolchain and SQLite headers for
the native gem builds:

```sh
sudo apt-get update
sudo apt-get install -y build-essential libsqlite3-dev
```

The first `index`/`search`/`conformance` run downloads the grammar libraries
into a local cache (one-time, requires network). After that the tool — and the
whole test suite — runs offline.

## Running the tests

```sh
bundle exec rake test
```

This is **the** command. The suite is deterministic and hermetic (no network).
Current baseline: **84 tests, ~94% line coverage** (SimpleCov). One test is
skipped by design — the live Ollama integration test, which requires a running
server. To include it:

```sh
CCE_OLLAMA_TEST=1 bundle exec rake test   # needs Ollama on localhost:11434
```

Coverage is written to `coverage/` (git-ignored).

## Quality gates

Every change must satisfy all of these before it can be merged:

1. **Tests pass** — `bundle exec rake test` is green (0 failures, 0 errors).
2. **Coverage maintained** — line coverage does not regress below the ~94%
   baseline. New code ships with new tests.
3. **Test-first** — write the failing test that pins the behaviour, then the
   minimum code to pass it. See [`docs/TDD.md`](docs/TDD.md) for the style.
4. **Spec conformance unchanged** — `bundle exec bin/cce conformance test/fixture`
   must still produce the committed `conformance.json` byte-for-byte, unless the
   change is an intentional, documented spec revision (a version bump).
5. **Docs updated** — if behaviour, flags, or architecture change, update the
   relevant file under `docs/` (and [`SPEC.md`](SPEC.md) / [`docs/DECISIONS.md`](docs/DECISIONS.md)
   for normative or ambiguity-resolving changes).

## Commit and PR conventions

- Keep commits focused and their messages in the imperative mood
  (e.g. `fix: correct fallback end_line for trailing newline`). A
  [Conventional Commits](https://www.conventionalcommits.org/) prefix
  (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`) is appreciated.
- Reference the issue you opened (`Closes #NN`).
- Open PRs against `main`. Fill in the pull-request template, including the
  gate checklist.
- Add a line to the `Unreleased` section of [`CHANGELOG.md`](CHANGELOG.md) for
  any user-visible change.

## Reporting bugs and requesting features

Use the GitHub issue forms:
<https://github.com/davidslv/cce-ruby/issues/new/choose>. Security issues must
**not** be filed as public issues — see [`SECURITY.md`](SECURITY.md).

## Code of Conduct

By participating you agree to abide by the
[Contributor Covenant](CODE_OF_CONDUCT.md).
