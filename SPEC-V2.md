# CCE v2 — Pluggable Language Packs (Specification v2.0)

**Status:** Normative. This is an **evolution** spec, not a from-scratch one. The
base engine is defined by `SPEC.md` (v1.0) and the dashboard by
`DASHBOARD-SPEC.md` (v1.1), both already in your repository and already
implemented. **This document specifies only the v2 changes.** Everything not
mentioned here is unchanged and must keep working (all existing tests stay
green).

**How this is built (read first):**
- You are a fresh sub-agent working **in your own existing repository** (Ruby
  agent in cce-ruby, Rust agent in cce-rust). You MAY and SHOULD read and
  refactor the existing code. This is **not** a clean-room build.
- Do all work on a branch named **`feat/language-packs`**. Commit there. **Do
  not push and do not open a PR** — the orchestrator verifies, then publishes.
- Do **not** read the sibling-language repository. The two implementations stay
  independent so the cross-language conformance gate (§7) remains meaningful.
- This is a **major release: v2.0.0** (breaking — the conformance output shape
  changes and the supported-language set changes).

**Goal:** rework language support into a **pluggable pack architecture** so the
core engine holds *zero* language-specific knowledge; convert the existing
Python and JavaScript support into packs; add **Ruby, Rust, TypeScript, and C**
packs; ship **validators** that make adding a pack safe and self-diagnosing; and
**sweep every Python/JavaScript assumption out of the code, comments, examples,
fixtures, and docs.**

---

## 1. The `LanguagePack` abstraction

Introduce a first-class **LanguagePack**. Each supported language is exactly one
pack — a small, self-contained unit that declares everything the engine needs to
know about that language. The core chunker/importer must reference **no language
by name**; it only ever talks to packs via this interface.

A pack declares/provides:

| Member | Meaning |
|---|---|
| `name` | unique lowercase id, e.g. `"ruby"` |
| `extensions` | file extensions it claims, e.g. `[".rb"]` (leading dot, lowercase) |
| `grammar()` | the tree-sitter `Language` to parse with |
| `function_types` | set of AST node-type strings that become `function` chunks |
| `class_types` | set of AST node-type strings that become `class` chunks |
| `extract_imports(root_node, source) -> [String]` | ordered, de-duplicated module/include names |
| `sample` | a small source snippet in this language (its self-test fixture, §6) |
| `expected` | what `sample` must produce: minimum function & class chunk counts, the set of `kind`s present, and the exact `imports` list |

Idiomatic shape per language: in Rust a `trait LanguagePack` with one struct per
language; in Ruby a duck-typed module/class per language with those methods.
Keep each pack in its own file under a `packs/` namespace
(`lib/cce/packs/ruby.rb`, `src/packs/ruby.rs`, …), each with a
why/what/responsibilities header describing **that language's** pack (this is
how the comment-bias problem is solved structurally — language knowledge and its
comments live only inside packs).

### 1.1 The registry

A **registry** owns the set of packs and resolves a file to its pack:
- `register(pack)` — adds a pack; **rejects a pack whose extension is already
  claimed** (see validation §5).
- `pack_for(path) -> pack | nil` — by lowercased file extension.
- `all -> [pack]` — for validation and `cce packs`.

The chunker becomes generic: `pack = registry.pack_for(path)`; if `nil`, produce
the language-neutral **module fallback** chunk (§4). Otherwise parse with
`pack.grammar()`, walk the tree, and for every node whose type is in
`pack.function_types` emit a `function` chunk and every node in
`pack.class_types` emit a `class` chunk — **including nested nodes** (a method
inside a class yields both the class chunk and the method chunk; a Rust `impl`
and the `fn` inside it both emit), exactly as the base engine already does.

Import extraction becomes generic too: `pack.extract_imports(root, source)`.

**Adding a language must be: add one pack file + register it + it passes
validation. No core edits.** A test must assert the core chunker/importer files
contain no hard-coded language names or extension literals (grep-style guard).

---

## 2. The six packs

Ship these six packs. Node-type sets below are the **intended mapping**; the
exact node-type spellings are answerable from each tree-sitter grammar and are
**enforced by the validators (§5)** — if you misspell one, the grammar-binding
lint and the self-test will fail, so get them from the grammar, not from memory.

| Pack | Extensions | function_types (intent) | class_types (intent) | imports from |
|---|---|---|---|---|
| `python` | `.py` | function definitions | class definitions | `import`, `from … import` |
| `javascript` | `.js`, `.jsx`, `.mjs`, `.cjs` | function decls, methods, arrow/function expressions | class declarations | `import … from "x"` |
| `ruby` | `.rb` | methods, singleton methods | classes, modules | `require`, `require_relative` |
| `rust` | `.rs` | function items | struct / enum / trait / impl / union items | `use` (first path segment) |
| `typescript` | `.ts`, `.tsx` | function decls, methods, arrow/function expressions | class / interface / enum declarations | `import … from "x"` |
| `c` | `.c`, `.h` | function definitions | struct / union / enum specifiers | `#include <…>` / `"…"` |

Import extraction rules (normative intent; resolve to a corpus file by stem, as
the base graph already does):
- **ruby:** the string argument of `require`/`require_relative`; take its last
  path segment's stem (`require "a/b"` → `b`).
- **rust:** the first segment of a `use` path (`use std::collections::HashMap` →
  `std`; `use crate::store::Index` → `crate`). `mod name;` may also be treated as
  an import of `name` (optional).
- **typescript:** the string module specifier's first path segment (`"./store"`
  → `store`, `"@scope/pkg"` → `@scope/pkg`), mirroring the JS rule.
- **c:** the `#include` target (a `preproc_include`); strip `<>`/quotes, take the
  basename without extension (`<stdlib.h>` → `stdlib`, `"store.h"` → `store`).

Grammar sourcing: **Ruby** — use the bundled grammar collection already in the
repo (it includes ruby/rust/typescript/c); **Rust** — add the per-language
grammar crates (`tree-sitter-ruby`, `tree-sitter-rust`, `tree-sitter-typescript`,
`tree-sitter-c`) to `Cargo.toml`, pinned. Keep grammar ABI compatibility with the
already-pinned `tree-sitter` core (the repo already documents this constraint).

---

## 3. Chunk model change: add `kind`

Keep the coarse `chunk_type` taxonomy — `function`, `class`, `module` (fallback)
— **unchanged**, because retrieval ranks on content and path, not on the label.

**Add one field to every chunk: `kind`** = the exact tree-sitter node-type string
that produced it (e.g. `"struct_specifier"`, `"trait_item"`,
`"interface_declaration"`, `"method"`, `"function_definition"`). For the module
fallback chunk, `kind = "module"`. `kind` is deterministic (straight from the
node type), so both implementations agree trivially. It is carried through
persistence, surfaced in `search`/`stats`/dashboard output, and appears in the
conformance output (§7). `kind` does **not** affect scoring, RRF, penalties, or
`chunk_id`.

`chunk_id` is unchanged (base SPEC §4.3): the `kind` field is not part of the id
hash.

---

## 4. Module fallback — fix the line-count ambiguity

For files with no matching pack (or that a pack parses to zero chunks), emit one
`module` fallback chunk over the whole file, as today. **Normative fix to close
the one v1 cross-language divergence:** the fallback chunk's
`end_line = (number of "\n" bytes in the file content) + 1` (a file ending in a
newline still counts that trailing line). `start_line = 1`, `chunk_type =
"module"`, `kind = "module"`. Both implementations must use exactly this rule so
the fallback chunk's id is identical across languages.

---

## 5. Pack validators (the safety rail)

A pack is **compatible** iff it passes three layers. Every diagnostic must name
the pack, the offending member, the problem, and — where possible — a fix.

**Layer 1 — structural lint.** `name` non-empty and unique; ≥1 extension, each a
lowercased leading-dot string; no extension already claimed by another pack;
the pack implements the full interface. (Rust gets most of this from the trait at
compile time; still assert extension-uniqueness at registration.)
- e.g. `[pack:ruby] extension ".rb" already claimed by pack "ruby-legacy"; each extension maps to exactly one pack.`

**Layer 2 — grammar-binding lint.** `grammar()` loads; **every string in
`function_types`, `class_types`, and every import node-type the pack looks for
exists as a real node kind in that grammar.** On a miss, suggest the nearest
valid node kind(s) by edit distance ("did you mean").
- e.g. `[pack:c] class_types: "struct_specifer" is not a node kind in tree-sitter-c. Did you mean: "struct_specifier", "union_specifier"?`
- e.g. `[pack:rust] grammar failed to load — add the "tree-sitter-rust" crate (Rust) / it is missing from the bundled grammars (Ruby).`

**Layer 3 — behavioural self-test.** Run the pack over its own `sample` and
assert it satisfies `expected`: at least the declared minimum `function` and
`class` chunk counts, the declared set of `kind`s present, **and
`extract_imports(sample) == expected.imports` exactly.** This catches a pack that
is structurally valid but wired to the wrong node type, and it validates import
extraction (per your requirement).
- e.g. `[pack:c] produced 0 class chunks from its sample; the sample defines a struct but class_types = {enum_specifier}. Add "struct_specifier".`
- e.g. `[pack:rust] imports mismatch: extracted ["std","std"] but expected ["std"] — dedupe, and take only the first use-path segment.`

**Surfaces (build all three):**
1. `cce packs` — list registered packs (name, extensions, grammar, #function/#class types). `cce packs --validate` — run all three layers over every pack and print diagnostics; exit non-zero if any pack fails.
2. **Test gate** — a test iterating every registered pack and asserting all three
   layers pass. CI blocks a broken pack.
3. **Fail-fast startup** — on engine construction, run only the cheap Layer-1
   checks (duplicate extension, unloadable grammar) and raise a clear error
   rather than silently mis-chunking.

---

## 6. Pack samples = the conformance fixture

Each pack ships a small `sample`. The samples are **also** the multi-language
conformance corpus, so the self-test and the cross-language equivalence gate are
one artifact.

Place these **exact** files under `test/fixture/samples/` (identical bytes in
both repos — do not alter them; the cross-language gate depends on byte
equality). `expected` for each pack is stated after it.

**`samples/python.py`**
```python
import os

def read_config(path):
    return os.path.join(path, "config.yml")

class Loader:
    def load(self):
        return read_config(".")
```
expected: ≥2 `function` (`read_config`, `load`), ≥1 `class` (`Loader`); kinds ⊇ {`function_definition`, `class_definition`}; imports == `["os"]`.

**`samples/javascript.js`**
```javascript
import fs from "fs";

function readConfig(path) {
  return fs.readFileSync(path);
}

class Loader {
  load() {
    return readConfig(".");
  }
}
```
expected: ≥2 `function` (`readConfig`, `load`), ≥1 `class` (`Loader`); imports == `["fs"]`.

**`samples/ruby.rb`**
```ruby
require "json"

def parse_config(text)
  JSON.parse(text)
end

class Loader
  def load(path)
    parse_config(File.read(path))
  end
end
```
expected: ≥2 `function` (kind `method`), ≥1 `class` (kind `class`); imports == `["json"]`.

**`samples/rust.rs`**
```rust
use std::collections::HashMap;

pub fn build_index() -> HashMap<String, u32> {
    HashMap::new()
}

pub struct Store {
    data: HashMap<String, u32>,
}

impl Store {
    pub fn get(&self, key: &str) -> u32 {
        0
    }
}
```
expected: ≥2 `function` (kind `function_item`: `build_index`, `get`), ≥2 `class` (kinds ⊇ {`struct_item`, `impl_item`}); imports == `["std"]`.

**`samples/typescript.ts`**
```typescript
import { readFile } from "fs";

export function loadConfig(path: string): string {
  return readFile(path);
}

export interface Config {
  name: string;
}

export class Loader {
  load(): Config {
    return { name: loadConfig(".") };
  }
}
```
expected: ≥2 `function` (`loadConfig`, `load`), ≥2 `class` (kinds ⊇ {`interface_declaration`, `class_declaration`}); imports == `["fs"]`.

**`samples/c.c`**
```c
#include <stdlib.h>

struct Node {
    int value;
};

int sum_node(struct Node *n) {
    return n->value;
}
```
expected: ≥1 `function` (kind `function_definition`: `sum_node`), ≥1 `class` (kind `struct_specifier`: `Node`); imports == `["stdlib"]`.

**`samples/notes.md`** (fallback — no pack claims `.md`)
```markdown
# Notes
Fixture for the module-fallback path.
```
expected: exactly 1 `module` chunk, `kind == "module"`, `start_line == 1`,
`end_line == 3` (two `\n` bytes + 1, per §4).

---

## 7. Conformance v2 (cross-language equivalence gate)

`cce conformance test/fixture/samples -o conformance.json` indexes the seven
sample files with **graph disabled** and emits, for every chunk, sorted by
`(file_path, start_line, chunk_id)`:
`{file_path, start_line, end_line, chunk_type, kind, chunk_id, token_count}`.
(The base conformance query section may be dropped or kept; the chunk section is
the gate.) The `kind` field is new in v2.

**Gate:** both repos ship byte-identical `samples/`; the orchestrator will diff
`conformance.json` between cce-ruby and cce-rust — the chunk arrays must be
**byte-identical** (this time including the fallback chunk, since §4 fixes the
line-count rule). Any difference is a bug to fix before publishing.

Each implementation must also include tests asserting the per-sample structural
`expected` from §6 (counts, kinds, imports) — these are hand-derivable and pin
the chunking without needing hard-coded sha256 ids.

---

## 8. Benchmark v2

Benchmark the four languages in active use; keep Python/JavaScript as validated
packs but do **not** ship labeled benchmark corpora for them.

`cce bench` gains a language dimension (or accepts a repo + language). For each,
clone shallowly at the pinned tag, record the exact commit in the report, index,
and measure the base metrics (index files/chunks/sec; query p50/p95;
Recall@5/@10; mean token savings) using the default hashing embedder.

**Corpus scope (normative).** `cce bench` indexes the **whole repository exactly
as `cce index` does**: files whose extension is claimed by a pack are AST-chunked
into function/class chunks, and every other in-scope text file becomes a single
fallback `module` chunk — all under the normal walk ignore rules (SPEC §7.1:
`.git/`, `.cce/`, `node_modules/`, `.venv`/`venv/`, `__pycache__/`, `dist/`,
`build/`, any dotdir; skip non-UTF-8 and files > 2 MB). There is **no**
bench-specific corpus filtering (no pack-extension-only subset). Both
implementations benchmark this identical whole-repo corpus, so Recall@5/@10 and
mean token savings must match **exactly** across the two implementations on the
same pinned commit; only latency differs by language/runtime.

| Lang | Repo (pin a recent stable tag; record the commit) | Suggested labeled queries → expected path substring |
|---|---|---|
| Ruby | `sinatra/sinatra` | "route matching and dispatch"→base · "render erb/haml template"→base · "session and cookies"→base · "mime type helpers"→base · "middleware stack"→base · "delegator methods"→base · "handle errors and show exceptions"→show_exceptions · "streaming responses"→base · "rack response building"→base · "url helpers"→base |
| Rust | `sharkdp/hyperfine` | "run a benchmark and measure timing"→benchmark · "parse command line options"→options · "export results as json"→export · "export as markdown"→export · "warmup runs"→benchmark · "shell spawning and command execution"→command · "outlier detection statistics"→outlier · "progress bar output"→benchmark · "parameter ranges"→parameter · "timing measurement"→timer |
| TypeScript | `pmndrs/zustand` | "create a store"→vanilla · "react hook to use the store"→react · "persist middleware"→middleware · "subscribe with selector"→middleware · "shallow equality"→shallow · "combine slices"→middleware · "devtools integration"→middleware · "set and get state"→vanilla · "immer middleware"→middleware · "context provider"→context |
| C | `jqlang/jq` | "parse a json value"→jv · "builtin functions"→builtin · "execute bytecode"→execute · "print/format json output"→jv_print · "lexer/tokenizer"→lexer · "compile the program"→compile · "object and array construction"→jv · "decode number"→jv · "main entry point"→main · "unicode handling"→jv_unicode |

If a target file doesn't exist at your pinned tag, drop that query and note it.
`docs/BENCHMARKS.md`: a per-language table plus one interpretive paragraph. Both
implementations will get **identical** recall/savings numbers on the same
whole-repo corpus (another cross-check); latency differs by language.

---

## 9. Documentation sweep (de-Python/JS)

Remove the Python/JavaScript bias everywhere a reader or agent looks:
- **README.md** — the "supported languages" list is now the six packs; the
  architecture blurb explains the pack model; rewrite any illustrative example
  so it is language-neutral or uses your languages (no Python/JS-only framing).
- **docs/architecture.md** — add a "Language packs" section: the interface, the
  registry, the validators, and the taxonomy (`chunk_type` + `kind`); keep an
  honest "where this would strain" note (e.g. one-extension-one-pack; grammars
  that need per-file dialect detection).
- **NEW: `docs/adding-a-language.md`** — the key DX artifact: a step-by-step
  guide to adding a pack (implement the interface, pick node types from the
  grammar, write the sample+expected, run `cce packs --validate`, read the
  diagnostics), with a worked example.
- **docs/how-to.md, docs/getting-started.md** — examples updated off Python/JS.
- **llms.txt, AGENTS.md** — mention the pack registry, the validators, and how to
  add a language; AGENTS.md notes the "no language names in core" guard.
- **Code comments** — the core carries no language-specific comments; each pack's
  comments describe its own language.
- **CHANGELOG.md / CITATION.cff / (Rust) Cargo.toml** — bump to **2.0.0**;
  CHANGELOG (Keep a Changelog) records: the pack architecture, the four new
  languages, the `kind` field, the fallback line-count fix, and the conformance
  output change as **breaking**.

---

## 10. TDD, gates, delivery

- **Test-first.** New tests must cover: the registry (resolution, duplicate-
  extension rejection), each pack's self-test (§6, incl. imports), all three
  validator layers with their diagnostics (including a deliberately-broken pack
  in a test asserting a *helpful* message), the "core has no language names"
  guard, the `kind` field end-to-end (index→persist→search/conformance), the
  fixed module-fallback line count, and the v2 conformance output.
- **All existing behaviour stays green**, plus: Ruby `bundle exec rake test`;
  Rust `cargo test` + `cargo clippy --all-targets --all-features -- -D warnings`
  + `cargo fmt --check`. Keep coverage at least at today's level (Ruby ≥93%,
  Rust ≥92%).
- Work on branch **`feat/language-packs`**, commit with clear messages, **do not
  push, do not open a PR.** Do not read the sibling repo.
- Report when done: the six packs + validators built; new test count + coverage;
  confirmation that `cce packs --validate` passes for all packs and prints
  helpful diagnostics for a broken one; the per-sample `expected` all pass; the
  v2 `conformance.json` produced; all gates green; and the `feat/language-packs`
  branch commit hash.
```
