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
