# How-to recipes

Task-oriented recipes for cce-ruby. For a guided first run, start with
[`getting-started.md`](getting-started.md). For the authoritative definition of
every behaviour here, the reference is **[`../SPEC.md`](../SPEC.md)**.

All commands assume you are in the repository root and have run `bundle install`.

## Index a repository

```sh
bundle exec bin/cce index path/to/repo
```

- Writes the store to `path/to/repo/.cce/index.db` by default.
- Choose a different location with `--store`:

  ```sh
  bundle exec bin/cce index path/to/repo --store /tmp/myrepo.db
  ```

- Re-indexing is idempotent: running it again on an unchanged directory produces
  a byte-identical store.

## Search a repository

```sh
bundle exec bin/cce search "hash the password" --dir path/to/repo --top-k 10
```

- `--dir DIR` loads the default store under `DIR/.cce/index.db`. Alternatively
  point directly at a store with `--store PATH`.
- `--top-k N` sets how many chunks to return (default follows the spec).
- `--json` emits machine-readable results (useful for agents/scripts).
- `--no-graph` disables import-graph expansion (return only directly retrieved
  chunks).

```sh
bundle exec bin/cce search "process payment" --dir path/to/repo --json --no-graph
```

## Inspect corpus statistics

```sh
bundle exec bin/cce stats --dir path/to/repo
```

Prints chunk/file counts, a per-language breakdown, average tokens per chunk,
and the store size on disk.

## Run the benchmark

Benchmark retrieval quality and latency against a pinned real repository and
write the report to `docs/BENCHMARKS.md`:

```sh
bundle exec bin/cce bench path/to/flask
```

- Provide your own labelled queries with `--queries FILE`.
- Override the store location with `--store PATH`.

See [`BENCHMARKS.md`](BENCHMARKS.md) for what the numbers mean.

## Run conformance

Emit the deterministic conformance output over the normative fixture corpus:

```sh
bundle exec bin/cce conformance test/fixture -o conformance.json
```

- The output is byte-for-byte reproducible run to run, and is designed to match
  the sibling Rust implementation ([davidslv/cce-rust](https://github.com/davidslv/cce-rust))
  chunk-for-chunk and score-for-score.
- To verify nothing has drifted, run it twice and diff, or compare against the
  committed `conformance.json`:

  ```sh
  bundle exec bin/cce conformance test/fixture -o /tmp/conf.json
  diff conformance.json /tmp/conf.json   # expect no output
  ```

This is the gate that protects cross-implementation equivalence. A change that
alters it is a spec revision (see [`../CONTRIBUTING.md`](../CONTRIBUTING.md)).

## Rate a search result (feedback)

Every `cce search` prints a `query-id` and records a metrics event. Mark a result
helpful or not so the dashboard can trend retrieval quality (v1.1):

```sh
bundle exec bin/cce search "hash the password" --dir path/to/repo
#   → …results…
#   → query-id: 3f9a1c2b7e04  ·  rate with: cce feedback 3f9a1c2b7e04 --helpful|--not-helpful

bundle exec bin/cce feedback 3f9a1c2b7e04 --helpful --dir path/to/repo
bundle exec bin/cce feedback 3f9a1c2b7e04 --not-helpful --note "wrong file" --dir path/to/repo
```

- Exactly one of `--helpful` / `--not-helpful` is required.
- `--json` search output carries the id as a top-level `"query_id"`.
- Feedback for an unknown id is still recorded (with a warning) — the log is
  append-only and future-tolerant.
- Skip recording on a one-off search with `--no-metrics`.

## View the dashboard

Serve the read-only, loopback-only metrics dashboard (v1.1):

```sh
bundle exec bin/cce dashboard --dir path/to/repo
#   → CCE dashboard (read-only, loopback-only) at http://127.0.0.1:8787/
#   → Press Ctrl-C to stop.
```

- Bound to `127.0.0.1` only; choose a port with `--port N` (default 8787), or an
  ephemeral port with `--port 0`.
- Point at a specific log with `--metrics PATH`, or a store/dir with
  `--store`/`--dir`.
- The page is fully self-contained (inline CSS/JS, hand-drawn SVG charts, no
  external network). It also exposes `GET /api/metrics` and `GET /api/health`,
  recomputed live from the log on each request.

See [`dashboard.md`](dashboard.md) for the event schema and aggregation formulas.

## Switch to the Ollama embedder

By default CCE uses the deterministic, offline `hash` embedder. To use a real
embedding model instead, run a local [Ollama](https://ollama.com/) server and
index with `--embedder ollama`:

```sh
# 1. Start Ollama and pull the model (one-time)
ollama pull nomic-embed-text

# 2. Index using the Ollama embedder (talks to http://localhost:11434)
bundle exec bin/cce index path/to/repo --embedder ollama

# 3. Search as usual — the store records which embedder produced it
bundle exec bin/cce search "authenticate a user" --dir path/to/repo
```

Notes:

- This is the **only** code path that makes a network call, and only to
  localhost. If the server is unreachable, CCE fails with a clear message rather
  than crashing.
- Ollama vectors are model-dependent, so this mode is **not** covered by
  conformance or the published benchmarks.

## Run the optional live Ollama test

The default suite skips the live Ollama integration test to stay hermetic. To
run it, start Ollama on `localhost:11434` and set the env var:

```sh
CCE_OLLAMA_TEST=1 bundle exec rake test
```
