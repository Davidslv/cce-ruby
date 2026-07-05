# Getting started

This guide takes you from nothing to your first successful **index** and
**search** with cce-ruby. No insider knowledge required — just follow along.

## 1. Prerequisites

- **Ruby 3.2 or newer.** Check with:

  ```sh
  ruby -v
  ```

  If you do not have Ruby, install it with your platform's manager
  (e.g. [rbenv](https://github.com/rbenv/rbenv), `asdf`, Homebrew, or your OS
  package manager).

- **Bundler** (ships with modern Ruby): `gem install bundler` if needed.

- **A C toolchain and SQLite headers** may be needed the first time native gems
  build. On Debian/Ubuntu:

  ```sh
  sudo apt-get update && sudo apt-get install -y build-essential libsqlite3-dev
  ```

  On macOS the Xcode command line tools (`xcode-select --install`) are enough.

## 2. Get the code and install dependencies

```sh
git clone https://github.com/davidslv/cce-ruby.git
cd cce-ruby
bundle install
```

## 3. Confirm it works

Run the test suite. It is deterministic and hermetic (no network) and should be
green:

```sh
bundle exec rake test
```

You should see something like `372 runs, ... 0 failures, 0 errors, 1 skips`
(the one skip is the optional live Ollama test). If this passes, your
environment is good.

## 4. Index a repository

Point CCE at any directory of source code. Here we use CCE's own `lib/` as a
handy example:

```sh
bundle exec bin/cce index lib
```

This walks the directory, AST-chunks each file into functions/classes, embeds
each chunk, and writes an index to `lib/.cce/index.db`.

> **First run note.** The very first time you index or search, CCE downloads the
> tree-sitter grammar libraries for its six supported languages (Ruby, Rust,
> TypeScript, C, Python, JavaScript) into a local cache (one-time, needs network).
> After that it runs fully offline.

## 5. Search it

Search runs from a fresh process, loading the store you just wrote:

```sh
bundle exec bin/cce search "cosine similarity" --dir lib --top-k 5
```

You will get the top-ranked code chunks, each with a file path, line span, and a
score. Add `--json` for machine-readable output, or `--no-graph` to disable
import-graph expansion:

```sh
bundle exec bin/cce search "bm25 keyword score" --dir lib --top-k 5 --json
```

## 6. Look at the corpus

```sh
bundle exec bin/cce stats --dir lib
```

This prints chunk and file counts, a per-language breakdown, a per-`kind`
breakdown (the exact tree-sitter node types), average tokens per chunk, and the
store size.

## 7. See the language packs

```sh
bundle exec bin/cce packs              # the six registered packs and their extensions
bundle exec bin/cce packs --validate   # run the validators over every pack
```

## Where to go next

- **[`how-to.md`](how-to.md)** — task recipes: benchmark a real repo, validate
  packs, run conformance, switch to the Ollama embedder.
- **[`workspace.md`](workspace.md)** — treat several related codebases under one
  root as one searchable ecosystem (`cce workspace init`, `cce index --workspace`).
- **[`sync.md`](sync.md)** — CCE Sync: push/pull a byte-identical index cache over
  a git remote so a teammate skips re-indexing (offline-first).
- **[`mcp.md`](mcp.md)** — wire CCE into Claude Code with `cce init` so the agent
  calls `context_search` as a native tool.
- **[`dashboard.md`](dashboard.md)** — the observability dashboard: savings,
  retrieval quality, agent-vs-human usage, index freshness, and secret-safety.
- **[`VERIFIED.md`](VERIFIED.md)** — recorded online AND offline cold-start
  transcripts: proof every core workflow runs with no network.
- **[`adding-a-language.md`](adding-a-language.md)** — add support for a new
  language as a self-contained pack.
- **[`architecture.md`](architecture.md)** — how the pipeline fits together and
  why it is built this way.
- **[`../SPEC.md`](../SPEC.md)** and **[`../SPEC-V2.md`](../SPEC-V2.md)** — the
  authoritative specifications: the source of truth for every behaviour above.

## Troubleshooting

- **A native gem fails to build** — install the system dependencies from step 1
  (a C compiler and SQLite headers), then re-run `bundle install`.
- **First `index`/`search` errors about grammars** — you likely have no network
  on the first run; the grammar cache download needs it once. Run again on a
  connected machine, then it works offline.
- **`search` says the store is missing** — index the directory first, or pass
  `--store PATH` pointing at an existing `index.db`.
