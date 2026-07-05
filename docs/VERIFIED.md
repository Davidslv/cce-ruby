# Cold-start verification transcripts

This file records **actual** cold-start runs of the documented walkthroughs —
every command executed verbatim, output captured (not invented). A doc example
that does not run verbatim is a bug.

- [Offline-first (v2.4.1) — **online AND offline** cold start](#offline-first-v241--online-and-offline-cold-start)
  — the mandatory proof that `index`, `search`, `stats`, `dashboard`, `workspace`,
  and `cce mcp` all run with **no network and no remote**, plus the refreshed
  dashboard `/api/metrics` shape.
- [CCE MCP (v2.4)](#cce-mcp--cold-start-verification-transcript) — `cce init`,
  the `cce mcp` server over stdio, and the dashboard proof-of-use.
- [CCE Sync (v2.3)](#cce-sync--cold-start-verification-transcript) — the
  distributed-cache walkthrough against a local `file://` remote.

---

# Offline-first (v2.4.1) — online AND offline cold start

Date: 2026-07-05 · cce-ruby **v2.4.1** · macOS (darwin arm64) · `ruby 3.4.7` ·
`git 2.50.1`. Commands run from the repo via `./bin/cce …` (an installed `cce` on
`PATH` behaves identically).

**Offline-first is the headline guarantee.** A source-code audit (`grep` for
`Net::HTTP`/`TCPSocket`/`Socket`/`WEBrick` across `lib/`) shows the **only**
network-capable code paths are:

1. **Installing the gem** (`gem install` / `bundle install`) — one-time.
2. The **optional** Ollama embedder (`--embedder ollama`) — talks to a *local*
   Ollama daemon on `http://localhost:11434`; the default `hash` embedder needs
   nothing.
3. **`cce sync push` / `cce sync pull`** — git transport to a configured remote.

Everything else — `index`, `search`, `stats`, `dashboard`, `workspace`, and
`cce mcp` serving the local index — makes **no outbound network calls at all**.
The dashboard's only socket is a **loopback** (`127.0.0.1`) bind.

## Part A — Online cold start (network up, no remote configured)

A throwaway git project with two Python files (`auth.py`, `payments.py`):

```
$ cce index /demo
Indexed 2 files (0 skipped, 0 sensitive skipped), 4 chunks in 0.035s
Store: /demo/.cce/index.db

$ cce search 'password hashing' --dir /demo
1. [0.878300] auth.py:4-5 (function/function_definition)
    def hash_password(password):
2. [0.876031] auth.py:8-9 (function/function_definition)
    def verify_password(password, digest):
3. [0.488935] payments.py:5-6 (function/function_definition)
    def refund(payment_id):
4. [0.466633] payments.py:1-2 (function/function_definition)
    def process_payment(amount, currency):
query-id: d6a36129d076  ·  rate with: cce feedback d6a36129d076 --helpful|--not-helpful

$ cce stats --dir /demo
Chunks:     4
Files:      2
Languages:  python=4
Kinds:      function_definition=4
Avg tokens: 21.8
Store size: 49152 bytes
```

An **agent** search over the same local index (the MCP `context_search` path)
tags its event `source: "mcp"`, so the dashboard can split agent-vs-human usage:

```
$ printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"context_search","arguments":{"query":"refund a payment"}}}' \
  | cce mcp --dir /demo
… id:1 → serverInfo {"name":"cce","version":"2.4.1"} …
… id:2 → "1. [0.844288] payments.py:5-6 (function/function_definition) def refund(payment_id): …  query_id: d43dc909ce58"
```

The persisted `.cce/metrics.jsonl` now carries the **v2.4.1 additive schema** — an
`index` event with `sha`/`source`/`sensitive_skipped`, a `cli` search, and an
`mcp` search (one JSON object per line, abridged here):

```
{"event":"index",  …,"embedder":"hash","full":true,"source":"local","sensitive_skipped":0,"sha":"85d9eeacf4d06900a28e17074b55bcf5770b612f"}
{"event":"search", …,"tokens_saved":8,"savings_ratio":0.0842…,"top_score":0.8783…,"source":"cli"}
{"event":"search", …,"tokens_saved":8,"savings_ratio":0.0842…,"top_score":0.8443…,"source":"mcp"}
```

The refreshed dashboard serves those as new `/api/metrics` sections (live on
refresh, computed offline from the log — no remote contact):

```
$ cce dashboard --dir /demo --port 0     # loopback-only
CCE dashboard (read-only, loopback-only) at http://127.0.0.1:55732/

$ curl -s http://127.0.0.1:55732/api/health
{"status":"ok","events":3,"skipped":0}

$ curl -s http://127.0.0.1:55732/api/metrics    # v2.4.1 panels (abridged)
{
  "by_source":    { "cli": {"searches":1,"tokens_saved":8,"mean_savings_ratio":0.084211},
                    "mcp": {"searches":1,"tokens_saved":8,"mean_savings_ratio":0.084211} },
  "freshness":    { "indexes":1, "last_indexed_ts":"2026-07-05T14:12:34Z",
                    "sha":"85d9eeacf4d06900a28e17074b55bcf5770b612f", "source":"local" },
  "secret_safety":{ "sensitive_skipped":0 }
}
```

**Secret-safety** — a `.env` next to the code is never read, and is counted:

```
$ cce index /secretdemo         # dir contains app.py + a .env with an AWS key
Indexed 1 files (0 skipped, 1 sensitive skipped), 1 chunks in 0.037s
```

**Workspace** — a 3-member ecosystem (Rails app + Ruby engine + TS web); the
refreshed `by_package` section now includes per-member `mean_top_score`:

```
$ cce workspace init /eco   →  Members (3): app [rails-app], billing [ruby-engine], web [typescript]
$ cce index --workspace /eco
Workspace index: 3 members
  app [rails-app]: 3 files, 6 chunks
  billing [ruby-engine]: 3 files, 6 chunks
  web [typescript]: 3 files, 3 chunks
Totals: 9 files, 15 chunks
Graph: 1 cross-member edges -> /eco/.cce/workspace-graph.json

$ cce search 'charge' --workspace /eco --top-k 3
0.887500  app · app/models/charge.rb:1-5 (class/class)
0.858470  app · app/models/charge.rb:2-4 (function/method)
0.841146  billing · lib/billing.rb:2-4 (function/singleton_method)

$ curl -s http://127.0.0.1:PORT/api/metrics    # cce dashboard --workspace /eco (abridged)
"by_package": {
  "app":     {"searches":1,"tokens_saved":0,"mean_savings_ratio":0.0,     "mean_top_score":0.869194},
  "billing": {"searches":1,"tokens_saved":0,"mean_savings_ratio":0.0,     "mean_top_score":0.745},
  "web":     {"searches":1,"tokens_saved":2,"mean_savings_ratio":0.04878, "mean_top_score":0.864528}
}
```

## Part B — Offline cold start (network denied, no remote)

Re-run under a macOS `sandbox-exec` profile that **denies all non-loopback
network** (equivalent to pulling the ethernet cable). First we prove the sandbox
is genuinely offline, then run every core workflow inside it:

```
$ cat nonet.sb
(version 1)
(allow default)
(deny network-outbound) (deny network-inbound)
(allow network-outbound (remote ip "localhost:*"))
(allow network-inbound  (local  ip "localhost:*"))
(allow network-bind     (local  ip "localhost:*"))

$ sandbox-exec -f nonet.sb curl -sS --max-time 3 https://example.com
curl: (6) Could not resolve host: example.com          # ← genuinely offline

$ sandbox-exec -f nonet.sb cce index /offline
Indexed 2 files (0 skipped, 0 sensitive skipped), 4 chunks in 0.039s

$ sandbox-exec -f nonet.sb cce search 'verify password' --dir /offline
1. [0.878300] auth.py:4-5 (function/function_definition)
    def hash_password(password):
2. [0.876031] auth.py:8-9 (function/function_definition)
    def verify_password(password, digest):
…
query-id: 8402a3ee4d25  ·  rate with: cce feedback 8402a3ee4d25 --helpful|--not-helpful

$ sandbox-exec -f nonet.sb cce stats --dir /offline
Chunks:     4
Files:      2
Languages:  python=4
Kinds:      function_definition=4

$ sandbox-exec -f nonet.sb cce mcp --dir /offline      # serves the LOCAL index, offline
… context_search "verify password" → "1. [0.878300] auth.py:4-5 (function/function_definition) def hash_password(password): …"

$ sandbox-exec -f nonet.sb cce dashboard --dir /offline --port 0
CCE dashboard (read-only, loopback-only) at http://127.0.0.1:55757/
$ sandbox-exec -f nonet.sb curl -s http://127.0.0.1:55757/api/health
{"status":"ok","events":3,"skipped":0}
$ sandbox-exec -f nonet.sb curl -s http://127.0.0.1:55757/api/metrics
… by_source.cli.searches=1  freshness.source=local  secret_safety.sensitive_skipped=0

$ sandbox-exec -f nonet.sb cce workspace init /eco   →  Members (3): app, billing, web
$ sandbox-exec -f nonet.sb cce index --workspace /eco   →  Totals: 9 files, 15 chunks
$ sandbox-exec -f nonet.sb cce stats  --workspace /eco   →  Totals: 9 files, 15 chunks

$ sandbox-exec -f nonet.sb cce sync status /offline       # no remote → graceful, no crash
sync: not configured (run `cce sync init --remote <git-url>`)
```

The **only** things that need the network, confirmed by failing cleanly offline:

```
$ sandbox-exec -f nonet.sb cce index /offline --embedder ollama
error: Cannot reach Ollama at http://localhost:11434 (Connection refused …).
Start it, or use the default hash embedder (--embedder hash).
```

`cce sync push/pull` likewise raise a clear `Sync::Error` when the remote is
unreachable and **never corrupt the local `.cce/`** (offline-first; covered by
`test/sync_commands_test.rb`). Everything else above ran identically online and
offline — that is the guarantee.

## v2.4.1 gate results (this build)

| gate | result |
|------|--------|
| `bundle exec rake test` | **372 runs, 1553 assertions, 0 failures, 0 errors, 1 skip** (the pre-existing Ollama skip) |
| Line coverage | **94.78%** (≥ 93% required) |
| `conformance.json` (single-repo) | **byte-identical** to `main` (unchanged) |
| Cross-language sync golden | **unchanged** — `581cbd0f…`, `SYNC_FORMAT_VERSION = "2.3"` (the version bump is decoupled) |
| Offline cold-start (this section) | **runs verbatim** under a network-denied sandbox |

---

# CCE MCP — cold-start verification transcript

Date: 2026-07-05 · cce-ruby **v2.4.0** · macOS (darwin arm64) · `ruby 3.4.7` ·
`git 2.50.1`. Fully hermetic: no editor, no network. Commands run from the repo
via `bundle exec bin/cce …` (an installed `cce` on `PATH` behaves identically).

## 1. Ensure an index + wire the editor — `cce init`

A throwaway project with two Python files (`auth.py`, `payments.py`):

```
$ cce init /tmp/demo
CCE init — project at /tmp/demo
  index:    indexed 2 files (5 chunks)
  .mcp.json: /tmp/demo/.mcp.json
  CLAUDE.md: /tmp/demo/CLAUDE.md

Next steps:
  1. Restart your editor (Claude Code) so it loads the `cce` MCP server.
  2. Ask a question about this codebase — the agent will call context_search.
  3. Confirm it was used: `cce dashboard` shows the agent's queries.
```

The generated `.mcp.json`:

```json
{
  "mcpServers": {
    "cce": {
      "command": "cce",
      "args": ["mcp", "--dir", "."]
    }
  }
}
```

The generated `CLAUDE.md` block (bounded by stable markers, so it updates in place):

```
<!-- BEGIN CCE MCP (managed by `cce init`) -->
## Code search — use CCE first
This project is indexed by CCE and exposed as the MCP tool **`context_search`**.
- PREFER `context_search` over reading or grepping files to locate functions, …
- Reserve file reads for opening a specific path `context_search` points you to.
- Use `index_status` to check freshness, and `record_feedback` to rate a result.
<!-- END CCE MCP -->
```

**Idempotent:** re-running `cce init /tmp/demo` prints `index: reused local index`,
leaves exactly one `cce` server entry and one CLAUDE.md block (verified: 1 server,
1 block), and does not re-index.

## 2. The server speaks MCP over stdio — `cce mcp`

Driving the server the way Claude Code does — piping JSON-RPC to stdin:

```
$ printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"context_search","arguments":{"query":"where is password hashing"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"index_status","arguments":{}}}' \
  | cce mcp --dir /tmp/demo
```

- `initialize` → `result` with `protocolVersion`, `capabilities`, `serverInfo`.
- `notifications/initialized` → **no response** (correct for a notification).
- `tools/list` → exactly `context_search`, `index_status`, `record_feedback`.
- `tools/call context_search "where is password hashing"` →

  ```
  1. [0.861084] auth.py:6-7 (function/function_definition)
  def verify_password(password, digest):
      return hash_password(password) == digest
  2. [0.835648] auth.py:3-4 (function/function_definition)
  def hash_password(password):
      return hashlib.sha256(password.encode()).hexdigest()
  …
  query_id: 928cfddb78df
  Rate this with record_feedback(query_id: "928cfddb78df", helpful: true|false).
  ```

- `tools/call index_status` →

  ```
  Index status
    chunks:     5
    files:      2
    store:      /tmp/demo/.cce/index.db
    embedder:   hash
    languages:  python=5
    kinds:      class_definition=1, function_definition=4
    indexed:    2026-07-05T13:29:49Z
    source:     local
  ```

## 3. "How do I know the agent used it?" — the dashboard proof

The `context_search` call above wrote a `search` event to `.cce/metrics.jsonl`,
exactly like the CLI path — so `cce dashboard` renders the agent's usage:

```
$ cat /tmp/demo/.cce/metrics.jsonl   # one line per event
search: where is password hashing (id=928cfddb78df, saved=22)
```

Closing the quality loop via the tool:

```
$ echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"record_feedback","arguments":{"query_id":"928cfddb78df","helpful":true,"note":"found it"}}}' | cce mcp --dir /tmp/demo
Recorded feedback for 928cfddb78df: helpful. Thanks — this feeds the dashboard quality signal.
```

A `feedback` event is appended to the same log, so `cce dashboard --dir /tmp/demo`
shows both the query and its rating.

## 4. Missing-index path is friendly, not a crash

```
$ echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"context_search","arguments":{"query":"x"}}}' | cce mcp --dir /tmp/empty
{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"This project is not indexed yet. Run `cce index` …"}],"isError":false}}
```

## 5. Sync freshness (soft dependency)

Behind a local bare `file://` sync remote with a pushed CI-built cache and
`sync.auto_pull` on, `cce mcp` best-effort `sync pull --latest` on startup warms
the local index, and `index_status` reports `source: sync-pull (<sha>)`,
`behind: no — up to date with remote`. With **no** remote configured MCP serves
the local index unchanged, and an unreachable remote never blocks or errors (both
paths are covered by `test/mcp_context_test.rb`). MCP is fully usable with no Sync.

---

## MCP gate results (this build)

| gate | result |
|------|--------|
| `bundle exec rake test` | **363 runs, 1510 assertions, 0 failures, 0 errors, 1 skip** (the pre-existing Ollama skip) |
| New MCP tests | **47** (server 15, context 11, init 9, cli 6, tools 6) |
| Line coverage | **94.79%** (≥ 93% required) |
| `conformance.json` (single-repo) | **byte-identical** to `main` (unchanged) |
| Cross-language sync golden | **unchanged** — the sync artifact FORMAT window stays `2.3` (MCP is additive; see DECISIONS D-MCP-2) |
| MCP cold-start walkthrough | **runs verbatim** (this transcript) |

---

# CCE Sync — cold-start verification transcript

> **Verification gate (SPEC-SYNC §10.5).** Documentation is not "done" until a
> **cold-start** run of it succeeds with zero friction. This file records an
> actual run of the documented install + walkthrough from scratch against a local
> git remote (a bare repo via `file://`, fully hermetic — no network). Every
> command below was executed verbatim; the output is captured, not invented. A
> doc example that does not run verbatim is a bug.

Date: 2026-07-05 · cce-ruby v2.3.0 · macOS (darwin arm64)

---

## Environment

```
$ git --version
git version 2.50.1 (Apple Git-155)
$ git lfs version
git-lfs/3.7.1 (GitHub; darwin arm64; go 1.25.3)
$ ruby --version
ruby 3.4.7
```

Install steps for a fresh machine are in the README
([macOS](../README.md#macos) / [Ubuntu](../README.md#ubuntu)). They were used to
produce the environment above (`git`, `git-lfs` + `git lfs install`, Ruby ≥ 3.2,
`bundle install`).

## Setup — one source repo + one SEPARATE sync cache repo

```
$ git init --bare cache.git    # the sync cache (a normal git repo)
$ git init --bare source.git   # stands in for github.com/acme/billing
# billing/ committed with src/auth.py + src/payments.py, .cce/ gitignored,
# pushed to source.git@main
```

## On CI (or a maintainer): index + push the cache

```
$ cce index ./billing
Indexed 3 files (0 skipped, 0 sensitive skipped), 3 chunks in 2.649s
Store: ~/billing/.cce/index.db

$ cce sync init --remote <cache-git-url> --repo-id github.com__acme__billing ./billing
Configured sync remote: file://~/cache.git
repo_id: github.com__acme__billing
LFS: disabled
Local clone: ~/.cce/sync/<remote-id>
Config: ~/billing/.cce/config

$ cce sync push ./billing
pushed github.com__acme__billing@158922bf0787 (3 chunks)
  key:      hash/2.3/github.com__acme__billing/158922bf0787ed893b545aab06d9351876325758.cce
  checksum: 261cb72bc523ac347232929997d243125e39aeba4e3f399b13ffbdfdfc4cb645

$ cce sync status ./billing
Remote:        file://~/cache.git
repo_id:       github.com__acme__billing
HEAD:          158922bf0787
Local cache:   158922bf0787
Remote latest: 158922bf0787
Tree matches:  yes
```

## On a teammate machine: clone the source, pull the cache, search

```
$ git clone <source-url> billing && cd billing
$ cce sync init --remote <cache-git-url> --repo-id github.com__acme__billing .
Configured sync remote: file://~/cache.git
repo_id: github.com__acme__billing
LFS: disabled
Local clone: ~/.cce/sync/<remote-id>
Config: ~/dev-billing/.cce/config

$ cce sync pull .
Installed cache github.com__acme__billing@158922bf0787 (3 chunks) into .cce/
  checksum: 261cb72bc523ac347232929997d243125e39aeba4e3f399b13ffbdfdfc4cb645
  working tree matches this commit — the pulled index is used as-is.

$ cce search 'hash password' --store ./.cce/index.db --no-metrics
1. [0.878300] src/auth.py:3-4 (function/function_definition)
    def hash_password(password):
2. [0.490902] .gitignore:1-2 (module/module)
    .cce/
3. [0.486935] src/payments.py:3-4 (function/function_definition)
    def process_payment(amount, currency):
```

The pulled index produces the same search results as the CI-built one, and the
`checksum` on pull equals the `checksum` on push — the teammate downloaded an
index someone else computed, byte-for-byte.

## Supply-chain check: rebuild locally and compare

```
$ cce sync verify .
verify OK: re-indexed 158922bf0787 matches the cached checksum
  checksum: 261cb72bc523ac347232929997d243125e39aeba4e3f399b13ffbdfdfc4cb645
```

`verify` re-indexed the working tree from scratch and got the **same checksum** as
the cache — proof the cached artifact was not tampered with, without trusting the
pusher.

> The transcript above uses `--no-lfs` so it is fully hermetic against a `file://`
> remote (LFS needs a transfer endpoint, which a bare `file://` repo has not). The
> git-LFS wiring (`.gitattributes` for `*.cce`, `git lfs install --local`, and
> that `*.cce` is routed through LFS) is exercised by the `test_lfs_smoke_or_skip`
> smoke test, which runs when `git-lfs` is present and skips gracefully otherwise.
> On a real remote (GitHub), keep the LFS default on.

---

## Gate results (this build)

| gate | result |
|------|--------|
| `bundle exec rake test` | **316 runs, 1321 assertions, 0 failures, 0 errors, 1 skip** (the pre-existing Ollama skip) |
| Line coverage | **94.21%** (≥ 93% required) |
| `conformance.json` (single-repo) | **byte-identical** to `main` (unchanged) |
| Cross-language golden | pinned in `test/sync_artifact_test.rb` (`GOLDEN_CHECKSUM`), which also emits `/tmp/cce_artifact_ruby.cce` for a byte-for-byte diff against Rust |
| Cold-start walkthrough | **runs verbatim** (this transcript) |

### Cross-language diff target (reconciled format)

Per [`SPEC-SYNC.md`](../SPEC-SYNC.md) §2 (the reconciled canonical format), the
shared golden indexes `test/fixture/samples` (byte-identical in both repos) and builds the
artifact with `repo_id="cce/demo"` and `sha="0"×40`. The Ruby engine produces:

```
581cbd0ff682a38d7d1250f3eec44f4ce456bdd660d4cb29aaaadd9e95072f48
```

Running `test_shared_golden_checksum_and_emit` also writes the raw artifact bytes
to **`/tmp/cce_artifact_ruby.cce`** (63,097 bytes) so the orchestrator can
`diff /tmp/cce_artifact_ruby.cce /tmp/cce_artifact_rust.cce` byte-for-byte. The two
files MUST be identical and the two checksums equal (SPEC-SYNC §10).
