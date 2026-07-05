# Workspaces / multi-codebase ecosystems (v2.2)

CCE indexes and searches a single repository. A **workspace** extends that to an
*ecosystem* of related codebases living under one root — for example a Rails
`app`, a `billing` engine, and a `web` frontend — searched as one whole, while
**each member stays isolated in its own store**. This document describes the
model, the manifest format, the detection rules, the federation semantics, and
where the design would strain. It is the reference for SPEC-V2.2.

## The model

Three pillars:

1. **Members are auto-detected** into a reviewable `.cce/workspace.yml`.
2. **Federated storage** — every member is indexed into its *own* `<member>/.cce/`
   exactly as a standalone repo. A workspace is a manifest that federates them.
   Nothing is stored centrally except two metadata files at the root:
   `.cce/workspace.yml` and `.cce/workspace-graph.json`.
3. **Level-1 relationships** — every result is tagged with its member, searches
   can be scoped with `--package`, and cross-member **dependency edges** are read
   from manifests (`Gemfile` / `*.gemspec` / `package.json`).

A **member** is a codebase inside the workspace with its own store at
`<member>/.cce/index.db` — identical to a standalone index of that directory.

## `.cce/workspace.yml` (the manifest)

Deterministic YAML at the workspace root. `members` is sorted by `path` ascending;
`name` is unique. A hand-written manifest is honoured as-is (member order
preserved); `cce workspace init` generates one and you may edit it.

```yaml
version: 1
name: myproduct
members:
  - name: app
    path: app
    type: rails-app
    package: app
  - name: billing
    path: engines/billing
    type: ruby-engine
    package: billing
  - name: web
    path: web
    type: typescript
    package: web
```

- `name` — the member id (the member directory basename; collisions get
  `-2`, `-3`, … in path-sorted order).
- `path` — workspace-root-relative, `/` separators.
- `type` — `rails-app | ruby-engine | ruby-gem | typescript | javascript`.
- `package` — the dependency name other members use to require/import it.

## Detection rules

`cce workspace init [<dir>]` walks `<dir>` with the standard ignore rules (skip
`.git`, `.cce`, `node_modules`, `.venv`/`venv`, `__pycache__`, `dist`, `build`,
any dotdir). A directory `D` is a **member** if it contains a **marker**; once
`D` is a member the walk does **not** descend into it (**members do not nest**).

Marker precedence (first match sets the type):

1. `D` has a `*.gemspec` → Ruby. `ruby-engine` if `D` also has `app/` **or**
   `config/routes.rb` **or** a `lib/**/engine.rb`; else `ruby-gem`.
2. `D` has `Gemfile` **and** `config/application.rb` → `rails-app`.
3. `D` has `package.json` → `typescript` if `D` has `tsconfig.json`, else
   `javascript`.

If the root itself matches a marker and has no sub-members, the root is the sole
member (the degenerate single-repo case).

**`package` name.** For a Ruby gem/engine it is the gemspec's `name`
(`s.name = "x"`), falling back to the gemspec filename stem. For TS/JS it is the
`name` field in `package.json`, falling back to the member directory basename.
For a Rails app it is the member directory basename.

## Cross-member dependency edges

`cce index --workspace` (and `workspace list` / `stats --workspace`) build
`.cce/workspace-graph.json`. For each member, the **declared** dependency names
are read from whichever manifests exist:

- `*.gemspec` — every `add_dependency` / `add_runtime_dependency` /
  `add_development_dependency` (first string argument).
- `Gemfile` — every `gem "name"` (first string argument; directives such as
  `gemspec` and options like `path:` / `git:` are ignored).
- `package.json` — the keys of `dependencies`, `devDependencies`,
  `peerDependencies`.

An edge `A → B` exists when a name `A` declares equals member `B`'s `package`
(or `B`'s `name`), tagged with its source `via` (`gemspec` | `gemfile` |
`package.json`). Edges are deduplicated and sorted by `(from, to, via)`.

```json
{ "members": ["app", "billing", "web"],
  "edges": [ { "from": "app", "to": "billing", "via": "gemfile" } ] }
```

## Federation semantics

`cce index --workspace` runs the *normal* single-repo pipeline per member into
`<member>/.cce/`, so language packs and secret scrubbing apply per member and a
member's store is **byte-identical to indexing that member standalone**. Members
may also be indexed independently; a workspace search federates whatever member
stores exist.

A **federated search** is *defined to equal* one standard retrieval (SPEC §6) run
over the **union of the in-scope members' stored chunks**:

1. Load each in-scope member's store; annotate every chunk with its `member`
   (its `file_path` stays member-relative).
2. Run the standard pipeline **once** over the union: query embed → vector +
   BM25 (stats over the union) → RRF → confidence blend → path penalty →
   per-file diversity cap (diversity key `(member, file_path)`) → top-K.
3. **Graph expansion** (unless `--no-graph`): the edge set is the union of each
   member's intra-store import graph **plus** the cross-member edges. A top
   result in member `A` with an `A → B` edge pulls up to
   `GRAPH_BONUS_MEMBER_CHUNKS` (2) chunks from `B`, bounded by
   `GRAPH_MAX_BONUS_MEMBERS` (2) distinct target members, scored as SPEC §6.7.

Because it is the same §6 over the same chunks, a workspace search over members
`{A, B}` returns the same ranked chunks (same order) as a single index built over
`A + B` — that equivalence is the correctness anchor, asserted in the tests.

`--package a,b` scopes the corpus to the named members (errors on an unknown
name). Each result carries its `package` (member) and member-relative
`file_path`.

## Stats & dashboard

- `cce stats --workspace` — a per-member table (files, chunks, by-kind), the
  workspace totals, and the cross-member edges.
- `cce dashboard --workspace` — federates each member's `<member>/.cce/metrics.jsonl`
  into one read-only, loopback-only dashboard: the existing north-stars as a
  workspace roll-up **plus a `by_package` breakdown** (savings & searches per
  member). Same posture as v1.1: loopback-only, read-only, self-contained.

## Where this would strain

- **Many stores per query.** A federated search loads every in-scope member's
  store into memory on each call. For a handful of members this is trivial; for a
  huge ecosystem (dozens of large members) reloading and re-embedding the union
  per query would dominate latency. A persistent, incrementally-updated union
  index would scale better but gives up the "federation == union, recomputed from
  the members' own stores" simplicity that makes isolation provable.
- **Edges are limited to declared manifests.** Level-1 relationships are only the
  dependencies a member *declares* in `Gemfile` / `*.gemspec` / `package.json`.
  Real coupling that lives elsewhere — a Rails engine mounted in `routes.rb`, a
  runtime `require` of a sibling, a TypeScript path alias — is not yet an edge.
  Those are Level-2 relationships for a later evolution.
- **Detection is heuristic.** The markers are deliberately simple. An unusual
  layout (a gem without a gemspec, an app whose `config/application.rb` lives
  elsewhere, a JS package with no `package.json`) will be missed — which is why
  the manifest is generated once and then **hand-editable**: fix it and re-run.
- **One store format across languages.** Members are byte-identical to standalone
  *within* an implementation; the cross-language equivalence anchor remains the
  per-member `conformance.json`, not the raw store bytes.
