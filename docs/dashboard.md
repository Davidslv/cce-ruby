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

**`search`** (appended by `cce search`):

```json
{"schema":"cce.metrics/v1","event":"search","ts":"…","id":"…",
 "query":"…","top_k":5,"graph_enabled":true,"embedder":"hash","result_count":3,
 "baseline_tokens":40000,"served_tokens":8000,"tokens_saved":32000,
 "savings_ratio":0.8,"top_score":0.9,"mean_score":0.7,
 "empty":false,"low_confidence":false,"latency_ms":5.0}
```

- `served_tokens` = Σ `token_count(content)` over the returned chunks.
- `baseline_tokens` = Σ whole-file `token_count` over the **distinct** files of
  the returned results (a missing entry contributes 0). Whole-file token counts
  are persisted by `cce index` (see below).
- `tokens_saved` = `max(0, baseline_tokens − served_tokens)`;
  `savings_ratio` = `tokens_saved / baseline_tokens` (0.0 when baseline is 0).
- `low_confidence` = `result_count > 0 AND top_score < 0.30`.

**`index`** (appended by `cce index`):

```json
{"schema":"cce.metrics/v1","event":"index","ts":"…","id":"…",
 "files_indexed":231,"chunks":1728,"index_bytes":123456,"duration_ms":740.0,
 "embedder":"hash","full":true}
```

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
