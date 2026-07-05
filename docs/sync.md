# CCE Sync — a distributed, offline-first cache for code-context indexes

> **Status:** shipped in v2.3.0. Implements [`SPEC-SYNC.md`](../SPEC-SYNC.md).
> Sync is **purely additive**: with no remote configured every existing command
> works exactly as before, and a failed `push`/`pull` never breaks local
> indexing or search.

CCE Sync is *git remotes for the index*. Your local `.cce/` store is always
authoritative. An optional git-backed remote is a **content-addressed cache** you
can push to and pull from. Because the index is a pure, deterministic function of
`(repo content @ commit, cce version, pack set, hash embedder)`, the cache for
`repo@sha` is **byte-identical** no matter who — or which language engine
(Ruby/Rust) — built it. So a cache pull is just downloading an index someone
already computed, and you can rebuild-and-compare to prove it.

- [When to use it](#when-to-use-it)
- [The model](#the-model)
- [The cache artifact (interchange format)](#the-cache-artifact-interchange-format)
- [Content address (cache key)](#content-address-cache-key)
- [The git remote backend & git-LFS](#the-git-remote-backend--git-lfs)
- [CLI reference](#cli-reference)
- [Configuration](#configuration)
- [Permissions](#permissions-delegated-to-git)
- [CI recipe](#ci-recipe-github-actions)
- [Offline-first guarantees](#offline-first-guarantees)
- [Troubleshooting](#troubleshooting)

---

## When to use it

- A team (or CI) has already indexed `main`; you want that index **instantly**
  instead of re-indexing on every clone.
- You want a **supply-chain check**: pull a cache and re-index locally to confirm,
  bit-for-bit, that nobody tampered with it (`cce sync verify`).
- You run the **Ruby and Rust** engines side by side and want one shared cache
  that both produce and consume.

If none of that applies, do nothing — CCE without a configured remote is exactly
the local-first engine it always was.

---

## The model

```
  CI on merge to main:   cce index (clean, hash embedder)  →  cce sync push
  a developer:           cce sync pull --latest  →  main@sha index, instantly
                         (work on a branch → run a normal `cce index` for WIP)
```

Two git repositories are involved and they are **not the same repo**:

| repo | holds | who writes it |
|------|-------|---------------|
| your **source** repo (`github.com/acme/billing`) | the code | developers |
| the **sync cache** repo | the `*.cce` artifacts | CI (and, safely, members) |

The sync cache is a normal, empty git repo you create once. `cce sync init`
points a project at it. Access control is entirely git's (see
[Permissions](#permissions-delegated-to-git)).

> **Branch overlay is out of scope in v1.** If your working tree differs from the
> pulled `sha`, run a normal `cce index` for a local index of your changes. The
> incremental "reindex only changed files on top of a pulled base" overlay is a
> documented fast-follow.

---

## The cache artifact (interchange format)

The Ruby store is SQLite and the Rust store is JSON, so the shared cache is
**neither** native store — it is a canonical, deterministic **interchange
artifact** both engines export and import. It is specified byte-exactly so the
blob for `repo@sha` is identical across people and across both engines, and so
`--verify` works cross-language.

The canonical format is pinned in
[`SPEC-SYNC-RECONCILE.md`](../SPEC-SYNC-RECONCILE.md) (the single format both
engines reconciled on). **Layout.** A UTF-8 stream with **LF after every line,
including the last**; all JSON compact (no insignificant whitespace) with keys
sorted lexicographically:

```
line 1        the manifest, as one compact sorted-key JSON object
lines 2..n-1  one compact sorted-key JSON object per chunk,
              sorted by (file_path, start_line, id)
line n        the graph, as {"edges":[…],"nodes":[…]}
```

**Manifest** (line 1) — exactly these keys, sorted; **no provenance** (no
`built_at`/`built_by`), so the file is reproducible:

```json
{"cce_version":"2.3","checksum":"…","chunk_count":3,"embedder":"hash","file_tokens":{"src/auth.py":18},"pack_set_id":"c,javascript,python,ruby,rust,typescript","repo_id":"github.com__acme__billing","sha":"…"}
```

`file_tokens` is a sorted-key object of whole-file token counts (the dashboard
baseline, DASHBOARD §3), carried so the round-trip is fully lossless.

**Chunk object** — one per line, exactly these keys (`id`, and an explicit
`language`):

```json
{"chunk_type":"function","content":"def …","embedding":"<base64>","end_line":4,"file_path":"src/auth.py","id":"…","kind":"function_definition","language":"python","start_line":3,"token_count":12}
```

- **Embeddings are NOT decimals.** A 256-d vector is **standard padded base64
  (no newlines) of its 256 little-endian IEEE-754 `f64` values** (2048 raw bytes).
  The hash embedder is deterministic, so these bytes are bit-equal across Ruby and
  Rust — base64 sidesteps any float→string formatting difference.

**Graph** (line n) — `{"edges":[…],"nodes":[…]}`. `nodes` are the corpus files,
one `{"id": path}` each, sorted by `id`; `edges` are the resolved file→file import
relations `{"source","target","type":"import"}`, sorted by `(source, target,
type)`:

```json
{"edges":[{"source":"src/payments.py","target":"src/auth.py","type":"import"}],"nodes":[{"id":"src/auth.py"},{"id":"src/payments.py"}]}
```

**Checksum.** `checksum` is the lowercase-hex **SHA-256 over the ENTIRE canonical
stream built with the manifest's `checksum` value set to the empty string `""`**;
the real hex is then written into the `checksum` field of the emitted artifact.
Verify = read the artifact, set `checksum` to `""`, re-hash, compare. There is no
provenance to special-case, and everything that determines the index — the
identity fields, `file_tokens`, every chunk, and the graph — is covered. The
`checksum` is the value the two engines diff to prove interoperability.

**Round-trip.** Import re-creates the store losslessly: chunk fields (incl. the
explicit `language`), bit-exact vectors, whole-file token counts, and the import
graph (file_imports are reconstructed from the edges so the rebuilt store's
graph-expansion — and graph-enabled search — is identical). An imported store
re-exports to byte-identical bytes.

---

## Content address (cache key)

A cache is addressed by its identity, so distinct commits are distinct files that
never conflict in content:

```
<embedder>/<cce_version major.minor>/<repo_id>/<sha>.cce
  e.g.  hash/2.3/github.com__acme__billing/9f1c2a….cce
```

- `embedder` is always `hash` — the only shareable embedder.
- `cce_version` at `major.minor` is a format-compatibility window; a mismatch is a
  cache **miss** (rebuild), never a silent wrong answer.
- `repo_id` is the normalized git origin (`host__org__repo`), or a configured
  `--repo-id` / `sync.repo_id` override. **Use an explicit `repo_id` when you want
  Ruby and Rust to key on the exact same string** (recommended for shared caches).
- `sha` is the commit the index was built from.

---

## The git remote backend & git-LFS

The remote is a plain git repository. A local **working clone** lives under
`~/.cce/sync/<remote-id>/`.

- `push` writes the artifact at its content-addressed path, commits, and
  `git push`es. Because every `sha` is a distinct file, the only possible race is
  git-ref advancement, handled with **fetch → rebase → retry**.
- `pull` fetches and reads the file.
- **Large blobs → git-LFS.** `*.cce` artifacts are large, so `cce sync init`
  (with LFS, the default) writes a `.gitattributes`:

  ```
  *.cce filter=lfs diff=lfs merge=lfs -text
  ```

  and runs `git lfs install --local` in the clone. Pass `--no-lfs` to use plain
  git (fine for small repos or a purely local `file://` remote).

The interface (`has`, `get`, `put`, `list`, `latest`) is backend-agnostic;
S3/GCS or a thin HTTP server are possible future backends without CLI changes.

---

## CLI reference

```
cce sync init  --remote <git-url> [--lfs | --no-lfs] [--repo-id <id>] [<dir>]
cce sync push  [--commit <sha>] [--workspace] [<dir>]
cce sync pull  [--commit <sha> | --latest] [--force] [--workspace] [<dir>]
cce sync status [--workspace] [<dir>]
cce sync verify [--commit <sha>] [<dir>]
```

- **`init`** writes `sync.*` into `<dir>/.cce/config`, sets up the working clone,
  and (with LFS) writes `.gitattributes`.
- **`push`** ensures a hash index for the current tree, exports the artifact, and
  puts it to the remote. It **refuses a dirty working tree** (commit first) and a
  **non-hash index** (only `hash` is shareable). Best-effort: it never blocks
  other work.
- **`pull`** fetches the cache for `HEAD` (or `--commit <sha>`, or `--latest` for
  the newest pushed `sha`), validates the checksum, and installs it into `.cce/`.
  It **will not silently replace** a local cache for a *different* `sha` without
  `--force`.
- **`status`** prints the remote, `repo_id`, HEAD, the local cache `sha`, the
  remote's latest, and whether your working tree matches.
- **`verify`** re-indexes the working tree in a throwaway store and confirms the
  cached artifact's checksum — the paranoid rebuild-and-compare.
- **`--workspace`** (SPEC-V2.2) iterates workspace members, each keyed by its own
  `repo_id__<package>@sha`.

---

## Configuration

`~/.cce/config.yml` (global) is merged **under** a per-project `<dir>/.cce/config`
(project wins). All keys are optional; absent ⇒ pure local CCE.

```yaml
sync:
  remote: git@github.com:acme/cce-cache.git   # the sync cache repo url
  lfs: true            # route *.cce through git-LFS (default true)
  repo_id: github.com__acme__billing          # override the derived repo_id
  auto_pull: false     # (reserved) pull latest on index/search when online
  retention: all       # all | keep-last-N
```

---

## Permissions — delegated to git

CCE adds **no RBAC of its own**. Access control is *whoever can pull the sync git
repo*. Guidance:

- A member of the sync repo can pull **any** cache in it, regardless of source
  access — so the sync repo's read access MUST equal the intended audience of
  every repo cached in it.
- **Uniform-access org →** one sync repo. **Compartmentalized repos →** one sync
  repo per access boundary; point different projects/workspaces at different
  `sync.remote`s.
- Redaction (v2.1) runs before any push, so no high-confidence secrets enter the
  cache — but it is still proprietary code, so the git gate matters.

---

## CI recipe (GitHub Actions)

Index `main` and push the cache on every merge. The only credential needed is
**write access to the sync cache repo** (not the source repo): a deploy key or a
PAT scoped to that one repo.

```yaml
# .github/workflows/cce-sync.yml
name: cce-sync
on:
  push:
    branches: [main]

jobs:
  push-cache:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # sync needs the real HEAD sha

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
          bundler-cache: true

      - name: Install git-LFS
        run: sudo apt-get update && sudo apt-get install -y git-lfs && git lfs install

      # Give git write access to the SEPARATE sync cache repo. Store a deploy key
      # (or PAT) scoped to that repo as the secret CCE_SYNC_DEPLOY_KEY.
      - name: Configure sync credentials
        env:
          KEY: ${{ secrets.CCE_SYNC_DEPLOY_KEY }}
        run: |
          mkdir -p ~/.ssh && echo "$KEY" > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan github.com >> ~/.ssh/known_hosts

      - name: Index and push the cache
        run: |
          bundle exec ruby -Ilib bin/cce index .
          bundle exec ruby -Ilib bin/cce sync init \
            --remote git@github.com:acme/cce-cache.git \
            --repo-id github.com__acme__billing .
          bundle exec ruby -Ilib bin/cce sync push .
```

> **Credential note:** scope the deploy key/PAT to the **sync cache repo only**.
> A leak grants write to the cache, never to your source. Members who can *read*
> the cache repo can pull; only CI (or trusted maintainers) need write.

---

## Offline-first guarantees (normative)

1. **No remote configured ⇒ every command behaves exactly as today.**
2. Remote configured but unreachable ⇒ `sync` commands fail **gracefully** with a
   clear message; all non-sync commands are unaffected.
3. The local `.cce/` store is always authoritative for local operations.
4. `pull` never silently overwrites a newer local index for a **different** `sha`
   without `--force`.

---

## Troubleshooting

| symptom | cause & fix |
|---------|-------------|
| `sync remote unreachable or rejected the operation: …` | Offline, wrong url, or missing git credentials. Local work is untouched. Check `git ls-remote <sync-url>`; fix SSH/HTTPS auth. |
| `refusing to push a dirty working tree` | You have uncommitted changes. Sync caches a *committed* `sha`. Commit (or stash), then push. Ensure `.cce/` is in `.gitignore`. |
| `index … was built with the 'ollama' embedder; only 'hash' indexes are shareable` | Semantic/Ollama indexes are non-reproducible and local-only. Re-index with the default hash embedder: `cce index <dir>`. |
| `cache miss for hash/2.3/…/<sha>.cce` | No cache exists for that commit (e.g. it hasn't been pushed yet, or the `cce_version`/`repo_id` differs). Push it, or run a local `cce index`. |
| `checksum mismatch: cached artifact … is corrupt` | The cached blob doesn't match its recorded checksum. Re-push a clean artifact; investigate the cache repo. |
| `refusing to replace <sha-a> with <sha-b>; pass --force` | A local cache for a different `sha` is present. This is guarantee #4. Re-run with `--force` if you really want to replace it. |
| `verify FAILED` | The locally rebuilt index does **not** match the cached checksum for that `sha` — treat the cache as untrusted. Confirm your working tree is exactly that commit and clean. |
| LFS: `This repository is configured for Git LFS but 'git-lfs' was not found` | Install git-LFS and run `git lfs install` (see the README install section), or `cce sync init --no-lfs` for plain git. |
| clone dir path looks odd for a `file://` remote | Cosmetic. The working clone is named from the remote url under `~/.cce/sync/<remote-id>/`; it is fully functional. |

A verified, end-to-end cold-start transcript of the whole flow is recorded in
[`VERIFIED.md`](VERIFIED.md).
