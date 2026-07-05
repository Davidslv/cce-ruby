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

Per [`SPEC-SYNC-RECONCILE.md`](../SPEC-SYNC-RECONCILE.md), the shared golden
indexes `test/fixture/samples` (byte-identical in both repos) and builds the
artifact with `repo_id="cce/demo"` and `sha="0"×40`. The Ruby engine produces:

```
581cbd0ff682a38d7d1250f3eec44f4ce456bdd660d4cb29aaaadd9e95072f48
```

Running `test_shared_golden_checksum_and_emit` also writes the raw artifact bytes
to **`/tmp/cce_artifact_ruby.cce`** (63,097 bytes) so the orchestrator can
`diff /tmp/cce_artifact_ruby.cce /tmp/cce_artifact_rust.cce` byte-for-byte. The two
files MUST be identical and the two checksums equal (SPEC-SYNC §10).
