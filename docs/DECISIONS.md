# Decisions

Every ambiguity in `SPEC.md` resolved during implementation, with rationale.
Where the spec was explicit, no decision was needed and none is recorded here.

## D1 — Grammar delivery (tree-sitter)

**Ambiguity:** The spec mandates tree-sitter but not how to obtain grammars in
Ruby. **Decision:** Use `ruby_tree_sitter` for parsing and
`tree_sitter_language_pack` for prebuilt Python/JavaScript grammar dylibs; load
them via `TreeSitter::Language.load`. We still walk the raw parse tree ourselves
so byte spans and node selection follow the spec exactly. Avoids a runtime C
build. Pinned in the Gemfile.

## D2 — Fallback chunk `end_line` = `content.count("\n") + 1`

**Ambiguity:** "end_line = number of lines" for the whole-file fallback (SPEC
§4.2) is underspecified for trailing newlines. **Decision:** Use
`content.count("\n") + 1`. This is exactly how tree-sitter numbers the end row of
a whole-file (module) node — verified empirically: a file `"a\nb\n"` yields an
end row of 2 → `end_line` 3. Choosing the tree-sitter-consistent value keeps
parsed and fallback chunks on the same line-numbering convention, which is the
most defensible reading and matters because `end_line` feeds the chunk id.

## D3 — ASCII-only lowercasing everywhere comparisons happen

**Ambiguity:** "lowercased query"/"lowercased chunk content" (SPEC §6.1, §6.5)
don't specify Unicode vs ASCII case folding. **Decision:** ASCII-only
lowercasing (`A–Z → a–z`), consistent with the tokenizer (SPEC §4.1). This keeps
intent classification and keyword substring checks aligned with how tokens are
produced, and avoids locale-dependent case folding.

## D4 — File-hint extraction for keyword confidence

**Ambiguity:** §6.5 defines a "file-hint" loosely and says "if you don't extract
hints, treat as none." **Decision:** Extract hints as whitespace-separated query
words containing a `.` (e.g. `app.py`), lowercased, and test them as substrings
of the (lowercased) `file_path`. The unique-query-token substring rule still
applies regardless. Simple, predictable, and never worse than "none".

## D5 — BM25 statistics recomputed on load

**Ambiguity:** §7 allows BM25 stats to be stored or recomputed. **Decision:**
Recompute the BM25 index from chunk contents when a store is opened. Corpora are
small (the spec says so), so this is cheap and keeps the store schema minimal and
unambiguous.

## D6 — Idempotency via full rebuild

**Ambiguity:** §7 requires idempotent re-indexing and "replace prior data for
changed/removed files." **Decision:** Each `write` fully replaces the corpus
(delete-all then insert-all in one transaction). Because chunk IDs are
deterministic, re-indexing the same directory produces identical state — the
simplest correct way to satisfy idempotency.

## D7 — Vector persistence format

**Decision:** Store each 256-dim embedding as a SQLite BLOB of little-endian
IEEE-754 doubles (`Array#pack("E*")`). Little-endian is fixed regardless of host
byte order, so stores are portable.

## D8 — Indexing scope (all text files, not only Python)

**Ambiguity:** §10.1 says "index the repo's Python sources," but the walker
(§7.1) and fixture (README.md → module chunk) require indexing all in-scope text
files. **Decision:** `index`/`bench` index every in-scope UTF-8 text file ≤2 MB
(honouring the ignore rules). This satisfies the fixture and the walker tests;
benchmark recall/token-savings are computed over the labeled queries regardless
of language mix. The bench report notes total files indexed.

## D9 — Rounding applied at comparison, sort, and emit boundaries

**Ambiguity:** §5.3 says round "wherever scores are compared, sorted, or
emitted." **Decision:** Internal maths runs in IEEE-754 doubles; rounding to 6dp
(half away from zero) is applied when sorting candidates (vector, BM25, final)
and when formatting emitted scores, with `chunk_id` ascending as the tie-break.
Ruby's `Float#round` already rounds half away from zero. Since both
implementations use the same algorithm and operation order in doubles, results
are effectively bit-identical; the rounding is the cross-language safety net the
spec intends.

## D10 — Conformance JSON formatting

**Ambiguity:** §8.3 requires byte-for-byte equality but the example is
pretty-printed. **Decision:** Emit `JSON.pretty_generate` (2-space indent) with a
fixed key order and stringified keys, matching the example's shape. The gate we
can fully control — identical output on repeated runs — is verified in tests and
by running the command twice. Scores are fixed 6-decimal strings via
`NumericFormat.fmt6` (no negative zero).

## D11 — Empty/whitespace query is a usage error at the CLI, empty results in the API

**Ambiguity:** §9 says invalid/empty inputs must not crash. **Decision:**
`Retriever#search` returns `[]` for a query with no tokens (library-level,
non-crashing). The CLI treats an empty/whitespace `search` query as a usage error
(exit code 2) with a friendly message, since the user almost certainly made a
mistake. Both paths are covered by tests.

## D12 — Store default location

**Decision:** Default store path is `<indexed-root>/.cce/index.db` (a hidden dir,
excluded from the walk), per §7. Overridable with `--store`.

## D13 — `search --json` becomes an object carrying `query_id` (DASHBOARD-SPEC §5)

**Ambiguity:** SPEC v1.0 §9 defines `search --json` as a bare array of result
objects; DASHBOARD-SPEC §5 says to add a **top-level** `query_id` field, which an
array cannot carry. **Decision:** In v1.1, `search --json` emits an object
`{"query_id": "<id>|null", "results": [ ...the v1.0 array... ]}`. The results
array is unchanged, so consumers only adjust to read `.results`. `query_id` is
`null` when metrics are disabled (`--no-metrics`). This is a documented v1.1
output change; it does not touch `conformance.json` (which is produced by the
Conformance module, not the CLI).

## D14 — Metrics failures are silent (fail-open), not warned to stdout/stderr

**Ambiguity:** DASHBOARD-SPEC §2 says a metrics write error should "log a warning
and continue." **Decision:** `EventLog#append` swallows every error and returns
`false` **without printing**. Printing to stderr/stdout from the metrics path
risks corrupting `--json` output and machine consumers, and the spec's overriding
requirement is that a metrics failure "must never break the command." Returning
`false` satisfies fail-open; the warning is omitted deliberately. `cce feedback`
is the one place we *do* warn (to stderr) — for an unknown `query-id` — because
that is user-facing, explicit input, not a background write.

## D15 — Metrics path derivation and the `<store-dir>/metrics.jsonl` location

**Ambiguity:** DASHBOARD-SPEC §2 places the log in "the store dir" and §5 adds a
`--metrics PATH`. **Decision:** Resolution order is: explicit `--metrics` wins;
else the log sits **next to the store** (`File.dirname(store)/metrics.jsonl`);
else under `<dir>/.cce/metrics.jsonl`. With the default store
(`<dir>/.cce/index.db`) this is `<dir>/.cce/metrics.jsonl`, matching the spec's
default `<indexed-dir>/.cce/`.

## D16 — Search metrics reflect the full returned result set (incl. graph bonus)

**Ambiguity:** DASHBOARD-SPEC §2.1 defines `served_tokens`/`baseline_tokens` over
"the returned results" without stating whether import-graph bonus chunks count.
**Decision:** They count — the event mirrors exactly what the user received. So
with graph expansion on, bonus chunks contribute to `served_tokens` and their
files to the distinct-file `baseline_tokens`. Rationale: the metric measures the
real token counterfactual of *this* response.

## D17 — `cce feedback` records even for an unknown `query-id`

**Ambiguity:** DASHBOARD-SPEC §5 allows either recording-with-a-warning or a
non-zero exit when the target id is absent. **Decision:** Record the feedback and
print a warning to stderr, exiting `0`. The log is append-only and future-tolerant;
a feedback event whose target has scrolled out of a rotated log (or was never
found) is still valid data, and refusing it would lose a user's signal.

## D18 — No config-file loading for metrics/dashboard in v1.1

**Ambiguity:** DASHBOARD-SPEC §1 lists optional config keys (`dashboard.port`,
`dashboard.input_price_per_million`, `metrics.enabled`). The base engine has no
config-file mechanism. **Decision:** Honour these as **defaults + CLI flags**
only: `--port` for the port, the `DEFAULT_INPUT_PRICE_PER_MILLION` constant for
price, and `--no-metrics` for `metrics.enabled=false`. A config-file loader is
out of scope for v1.1 (backlog), keeping parity with the base engine's
constants-only approach.

## D19 — Metrics subsystem is the one place wall-clock time is allowed

**Decision (per DASHBOARD-SPEC §0):** `ts`/`id`/`generated_ts` use real wall clock
and randomness, injected via `SystemClock`/`RandomIdSource` (production) and
`FixedClock`/`SequenceIdSource`/`SequenceClock` (tests). The **aggregator** takes
`now` as a parameter and contains no clock or randomness, so it stays pure and
cross-language-identical (the §4.1 anchor). CLI metrics tests exercise the real
clock but never assert on `ts`/`id`, so the suite stays deterministic.
