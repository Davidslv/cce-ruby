# Dashboard & observability

Added in **v1.1** (DASHBOARD-SPEC). This document describes the metrics pipeline,
the persisted event schema, the aggregation formulas, and where the design would
strain. For the authoritative definition, see
[`../DASHBOARD-SPEC.md`](../DASHBOARD-SPEC.md).

The goal is narrow and honest: give an LLM user **observability** into whether
using CCE is *improving or degrading their experience over time*, from **persisted
data**, along two north-star lenses — **(A) token & cost savings** and **(B)
retrieval quality**.

## The pipeline

```
cce search / index / feedback
    │  append one JSON line (best-effort, fail-open)
    ▼
<store-dir>/metrics.jsonl            ← the persisted event log (append-only)
    │  read + skip corrupt/blank lines
    ▼
CCE::Metrics::Aggregator.aggregate(events, now:, price:)   ← PURE function
    │  totals · north-stars · daily series · recent searches
    ▼
GET /api/metrics  (JSON)   ─┐
GET /api/health   (JSON)    ├─ CCE::Dashboard::App  →  CCE::Dashboard::Server (WEBrick, 127.0.0.1)
GET /            (HTML)    ─┘   self-contained page fetches /api/metrics and draws SVG charts
```

Module map (all under `lib/cce/`):

| File | Role |
|---|---|
| `metrics.rb` | Constants + injectable clock/id sources (`SystemClock`, `FixedClock`, `RandomIdSource`, …). |
| `metrics_event_log.rb` | Append/read the JSONL log; fail-open writes, corruption-tolerant reads. |
| `metrics_recorder.rb` | Build the three event kinds; derive the search fields. |
| `metrics_aggregator.rb` | The pure aggregate function (the cross-language anchor). |
| `dashboard_app.rb` | Read-only request router → `Response(status, content_type, body)`. |
| `dashboard_page.rb` | The single self-contained HTML/CSS/JS document. |
| `dashboard_server.rb` | Thin WEBrick wrapper bound to loopback. |

The metrics subsystem is the **one place** in CCE that uses wall-clock time and
randomness (`ts`, `id`, `generated_ts`). Both are injected, so tests are
deterministic; the aggregator itself takes `now` as a parameter and is pure.

## Event schema (`metrics.jsonl`)

One JSON object per line, UTF-8. Every event carries `schema`
(`"cce.metrics/v1"`), `event`, `ts` (ISO-8601 UTC, second precision), and `id`
(12 lowercase-hex chars).

**`search`** (appended by `cce search` and the MCP `context_search` tool):

```json
{"schema":"cce.metrics/v1","event":"search","ts":"…","id":"…",
 "query":"…","top_k":5,"graph_enabled":true,"embedder":"hash","result_count":3,
 "baseline_tokens":40000,"served_tokens":8000,"tokens_saved":32000,
 "savings_ratio":0.8,"top_score":0.9,"mean_score":0.7,
 "empty":false,"low_confidence":false,"latency_ms":5.0,
 "source":"cli","package":"billing"}
```

- `served_tokens` = Σ `token_count(content)` over the returned chunks.
- `baseline_tokens` = Σ whole-file `token_count` over the **distinct** files of
  the returned results (a missing entry contributes 0). Whole-file token counts
  are persisted by `cce index` (see below).
- `tokens_saved` = `max(0, baseline_tokens − served_tokens)`;
  `savings_ratio` = `tokens_saved / baseline_tokens` (0.0 when baseline is 0).
- `low_confidence` = `result_count > 0 AND top_score < 0.30`.
- **`source`** (v2.4.1, additive) — `"cli"` for the human CLI path, `"mcp"` for
  the agent/`context_search` path. Drives the agent-vs-human panel. Absent on
  pre-v2.4 logs, which then read as `"cli"`.
- **`package`** (v2.4.1, optional) — the workspace member/package filter, when one
  was applied; omitted otherwise.

**`index`** (appended by `cce index` and by `cce sync pull`):

```json
{"schema":"cce.metrics/v1","event":"index","ts":"…","id":"…",
 "files_indexed":231,"chunks":1728,"index_bytes":123456,"duration_ms":740.0,
 "embedder":"hash","full":true,
 "source":"local","sensitive_skipped":4,"sha":"9f3c1ab77e20d41c"}
```

- **`source`** (v2.4.1) — `"local"` for a `cce index` run, `"sync-pull"` for an
  index installed by `cce sync pull`. Drives the freshness panel's local-vs-pulled
  reading.
- **`sensitive_skipped`** (v2.4.1) — how many files the secret-safe walker refused
  to read on this run. Summed across index events for the secret-safety panel.
- **`sha`** (v2.4.1, optional) — the VCS commit the index was built from / pulled
  at; omitted when the directory is not a git repo.

**`feedback`** (appended by `cce feedback`):

```json
{"schema":"cce.metrics/v1","event":"feedback","ts":"…","id":"…",
 "target_id":"<a search event id>","helpful":true,"note":""}
```

**Whole-file token persistence.** To compute `baseline_tokens` accurately, `index`
stores a `file_path → token_count(entire file)` map in the SQLite store (table
`file_tokens`). At search time the baseline sums those counts over the distinct
result files.

**Robustness.** The reader skips malformed/blank lines (counting them as
`skipped`) and tolerates unknown future fields. An absent log is an empty
dataset, rendered as a friendly "no data yet" state — never an error.

## Aggregation formulas

`aggregate(events, now, price)` is a pure function. Windows are defined relative
to the injected `now`:

- **Current window:** `now − 7d ≤ ts < now`.
- **Prior window:** `now − 14d ≤ ts < now − 7d`.

Measures (per set of searches / feedback):

- `mean_savings_ratio` = mean of `savings_ratio` over the searches (empties
  contribute their stored `0.0`); `0.0` if none.
- `mean_top_score` = mean of `top_score` over **non-empty** searches
  (`result_count > 0`); `0.0` if none.
- `empty_rate` = empty searches / total searches; `0.0` if none.
- `low_conf_rate` = low-confidence searches / total searches; `0.0` if none.
- `helpful_rate` = `helpful / (helpful + not_helpful)`, or **null** when there is
  no feedback in the set.
- `direction(delta)` = `"up"` if `delta > 1e-9`, `"down"` if `delta < −1e-9`,
  else `"flat"`. For both north-stars higher is better, so `"up"` = improving.

Output rounding is applied **only at the boundary**: ratios/scores/rates → 6
decimals, cost → 2 decimals, both round-half-away-from-zero; counts and token
sums stay integers. The savings north-star's `delta_ratio` is the change in
`mean_savings_ratio`; the quality north-star's `delta_top_score` is the change in
`mean_top_score`.

`series.daily` has one entry per UTC calendar date that has **any** search or
feedback event (an index-only day is omitted), sorted ascending. Each day's
`mean_top_score` uses that day's non-empty searches. `recent_searches` returns up
to 20 most-recent search events, newest first, with the feedback state resolved
by matching `feedback.target_id == search.id` (latest feedback wins).

The DASHBOARD-SPEC §4.1 anchor over
[`../test/fixture/metrics_sample.jsonl`](../test/fixture/metrics_sample.jsonl)
is the cross-language equivalence gate — both the Ruby and Rust implementations
must reproduce its numbers exactly (`test/metrics_aggregator_test.rb`).

## v2.4.1 refreshed panels (additive `/api/metrics` sections)

Since v1.1 the engine gained workspaces (v2.2), Sync (v2.3), MCP (v2.4) and
secret-scrubbing (v2.1). The **v2.4.1 dashboard refresh** surfaces what those made
valuable, as three new top-level `/api/metrics` sections (plus one field on the
workspace `by_package`). Every one degrades gracefully on old logs, and — like the
rest of the aggregate — is computed **offline from the log** (no remote contact),
so the dashboard stays fully offline.

These keys are the **single cross-engine canonical contract** — cce-ruby and
cce-rust emit byte-identical shapes.

```json
{
  "totals": { "…": "…", "mean_top_score": 0.633333 },
  "by_source": {
    "cli": {"searches": 21, "tokens_saved": 105274, "mean_savings_ratio": 0.585000, "mean_top_score": 0.712000},
    "mcp": {"searches": 18, "tokens_saved":  98901, "mean_savings_ratio": 0.601000, "mean_top_score": 0.704000}
  },
  "index_freshness": {
    "indexes": 1, "source": "sync-pull",
    "sha": "9f3c1ab77e20d41c", "indexed_ts": "2026-06-25T09:00:00Z"
  },
  "secret_safety": { "sensitive_skipped": 4, "index_runs": 1 }
}
```

- **`totals.mean_top_score`** — mean rank-1 score over the log's non-empty searches
  (the unwindowed twin of north-star B).
- **`by_source` — agent vs human.** Every search bucketed by `source`
  (`mcp` = agent/`context_search`, everything else = `cli`), so you can see how
  much your agent leans on CCE vs your own CLI use. Pre-v2.4 searches bucket as
  `cli`. Each bucket carries `searches`, `tokens_saved`, `mean_savings_ratio`, and
  `mean_top_score`.
- **`index_freshness` — index freshness / sync status.** Derived from the
  most-recent `index` event: `indexes` (run count), `source` (local vs
  `sync-pull`), `sha`, and `indexed_ts`. **"Behind remote" is deliberately not
  here** — it needs a network round-trip, so it lives in `cce sync status` (an
  explicit network action) and the MCP `index_status` tool, keeping the served
  dashboard offline.
- **`secret_safety` — redaction reassurance.** `sensitive_skipped` summed across
  index events (files the secret-safe walker refused to read), plus `index_runs`
  (how many index events contributed).

**Workspace `by_package`** (from `cce dashboard --workspace`) rolls the ecosystem
up per member as a **sorted array of objects** (each with a `package` field) that
now includes per-member retrieval quality:

```json
"by_package": [
  {"package": "app",     "searches": 1, "tokens_saved": 0, "mean_savings_ratio": 0.0,     "mean_top_score": 0.869194},
  {"package": "billing", "searches": 1, "tokens_saved": 0, "mean_savings_ratio": 0.0,     "mean_top_score": 0.745000},
  {"package": "web",     "searches": 1, "tokens_saved": 2, "mean_savings_ratio": 0.04878, "mean_top_score": 0.864528}
]
```

The self-contained page renders these as an **Agent vs human usage** panel, an
**Index freshness · sync · secret-safety** panel, and (workspace mode) a
**Per-member breakdown** table. See [`dashboard.png`](dashboard.png) for the
current layout and [`VERIFIED.md`](VERIFIED.md) for a captured run.

## The web dashboard

`cce dashboard` starts a WEBrick server **bound to 127.0.0.1**. It is
**read-only** (no endpoint mutates anything) and **fully self-contained**: the
served HTML inlines all CSS and JS and draws its own SVG charts — no external
network, CDN, or remote fonts/scripts. `GET /api/metrics` recomputes the
aggregate from the current log on each request, so a browser refresh reflects new
events live.

See the [Security policy](../SECURITY.md) for the dashboard's place in the threat
model.

## Where this would strain

- **The log grows unbounded.** `metrics.jsonl` is append-only with **no rotation
  or compaction in v1.1**. On a busy machine it will grow without limit, and the
  aggregator reads the whole file per `/api/metrics` request — fine for a local
  dev tool, but it would need rotation/roll-up (or a real time-series store) at
  scale.
- **Whole-file reads on every request.** Aggregation is O(events) each call. That
  is cheap for a personal log but not for a shared, high-volume one.
- **No concurrency control on the log.** Appends are best-effort `File.open(…,
  "a")`; interleaved writers on the same file could in principle tear a line. The
  reader tolerates that (it skips a corrupt line), but the write side assumes a
  single local user.
- **Latency and usage-volume are captured but not surfaced.** `latency_ms` and
  raw counts live in the data; dedicated dashboard panels for them are backlog.
- **Loopback trust.** The server binds 127.0.0.1 and needs no token. If it were
  ever allowed to bind a non-loopback address, it would require an auth token
  (mirroring the base security model) — not implemented, because v1.1 never
  offers a non-loopback bind.
