# Security Policy

## Supported versions

cce-ruby follows [Semantic Versioning](https://semver.org/). Security fixes are
provided for the current minor series only.

| Version | Supported |
|---|---|
| 2.3.x   | ✅ |
| 2.2.x   | ✅ |
| < 2.2   | ❌ |

## Threat model

CCE is a **local command-line tool**. Understanding its actual attack surface
matters more than boilerplate, so here is the real picture.

- **Trust boundary: the local filesystem.** The tool reads and parses source
  files from a directory you point it at, and writes an index to disk under a
  store directory (`<dir>/.cce/index.db` by default).
- **Indexed file contents are untrusted data.** The primary exposure is the
  **tree-sitter parser**: CCE feeds arbitrary local source files to
  `ruby_tree_sitter` / `tree_sitter_language_pack` grammars. A maliciously
  crafted input file could, in principle, trigger a bug in the parser or the
  native bindings. CCE treats parsed content strictly as **data** and walks the
  parse tree defensively.
- **CCE does not execute the code it indexes.** It parses and analyses source;
  it never runs it, imports it, or evaluates it.
- **Secrets are protected by default (v2.1).** Indexing is secret-safe unless you
  opt out. **Layer 1**: files that are sensitive *by name* — private keys and
  keystores (`pem`, `key`, `p12`, `pfx`, `keystore`, `jks`, `ppk`, `der`, `asc`),
  credential files (`credentials.*`, `secrets.*`, `.netrc`, `.pgpass`,
  `.htpasswd`, `.dockercfg`, `kubeconfig`, `id_rsa`/`id_dsa`/`id_ecdsa`/
  `id_ed25519`), and `.env`/`.env.*` (safe `.example`/`.sample`/`.template`/
  `.dist` templates excepted) — are **never read** and are tallied as
  `sensitive_skipped`. **Layer 2**: high-confidence secrets found *inside*
  indexed files (cloud/API keys, private-key blocks, JWTs, and guarded
  `key = value` assignments) are **redacted to `[REDACTED:<LABEL>]` before the
  content is chunked, embedded, or stored**, so the on-disk store never holds the
  secret value. Both layers are deterministic. **Residual risk:** the store is
  still a **local-only** artifact under `.cce/…` — protect that directory as you
  would any local file; redaction is defence-in-depth, not a licence to index
  untrusted secret material. The `--allow-secrets` flag disables **both** layers
  for a run (it prints a warning), after which sensitive files are read and inline
  secrets are stored verbatim — use it only deliberately.
- **No network calls by default.** The default `hash` embedder is fully local
  and deterministic. The tool makes **no** outbound connections during normal
  `index`/`search`/`stats`/`conformance` operation. (A first run may download
  tree-sitter grammar libraries into a local cache; after that it is offline.)
- **The only optional network path is opt-in.** Passing `--embedder ollama`
  makes CCE talk to a local [Ollama](https://ollama.com/) server over
  **localhost HTTP** (`http://localhost:11434`). This is opt-in, localhost-only,
  and fails gracefully with a clear message if the server is unreachable. No
  other host is ever contacted.
- **CCE Sync is opt-in, git-transported, and RBAC-free by design (v2.3).**
  `cce sync …` is inert unless you configure a `sync.remote`. When configured, all
  transport, authentication, and access control are **git's own** (SSH/HTTPS
  credentials) — CCE reinvents no auth. Consequences to design for:
  - **A sync-repo reader can pull every cache in it.** Access to a cached index is
    exactly access to the sync git repo, *independent of source-repo access*.
    Give the sync repo read access equal to the intended audience of every repo
    cached in it; use **one sync repo per access boundary** for compartmentalized
    projects. Scope any CI push credential to the **sync cache repo only** — a leak
    grants write to the cache, never to your source.
  - **Caches are proprietary code.** v2.1 redaction runs before any push, so
    high-confidence secrets do not enter the cache, but chunk *content* is your
    source — the git read gate is what protects it.
  - **Only reproducible `hash` indexes are shareable.** `push` refuses a non-hash
    (Ollama) index, so non-deterministic vectors never leave your machine.
  - **Pull trusts the checksum; `verify` does not.** By default `pull` trusts the
    artifact's recorded checksum (and rejects a self-inconsistent one). For
    supply-chain assurance, `cce sync verify` **re-indexes locally and compares**,
    so you never have to trust the pusher. A failed `push`/`pull` is best-effort
    and never mutates the local `.cce/` store.
- **The dashboard server is loopback-only, read-only, and self-contained (v1.1).**
  `cce dashboard` starts a WEBrick HTTP server **bound to `127.0.0.1`** — it does
  not listen on any external interface, so it is not reachable from the network.
  Every endpoint is **read-only**: `GET /`, `GET /api/metrics`, `GET /api/health`
  only *read* the metrics log; nothing mutates state. The served page is **fully
  self-contained** — all CSS/JS is inlined and charts are hand-drawn SVG, with
  **no external network, CDN, or remote fonts/scripts** — so opening it makes no
  outbound request. Because the bind is loopback and never leaves the local
  machine, no auth token is required; **if a future version ever allowed binding
  a non-loopback address, it would require a token** (mirroring this model).
- **The metrics log is local, best-effort data.** Events are appended to
  `<store-dir>/metrics.jsonl`. Writing is fail-open (a failure never breaks the
  command and never raises), and it records only what you searched/indexed and
  your feedback — it is not transmitted anywhere.

### Workspace mode (v2.2)

Workspace mode adds no new trust boundary. Two consequences worth stating:

- **Workspace metadata is non-secret.** `.cce/workspace.yml` and
  `.cce/workspace-graph.json` hold only member names, relative paths, types,
  declared dependency names, and edges — derived from files already in the repo.
  They are safe to commit and review.
- **Per-member secret scrubbing still applies, unchanged.** `cce index
  --workspace` runs the *normal* pipeline per member, so Layer 1 (sensitive-file
  skipping) and Layer 2 (inline-secret redaction) protect each member's store
  exactly as for a standalone repo. A member's store is byte-identical to
  indexing that member alone, secrets included. The federated dashboard is
  loopback-only and read-only, like the single-repo dashboard.

### Out of scope

- Compromise resulting from running CCE against a directory you do not trust
  *and* separately executing that code yourself — CCE does not do that for you.
- The security of a third-party Ollama server you choose to run.
- Supply-chain integrity of the upstream gems (`sqlite3`, `ruby_tree_sitter`,
  `tree_sitter_language_pack`, `webrick`) beyond pinning them in the `Gemfile`;
  report those to their respective maintainers.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems.**

Report privately through either of:

1. **GitHub Security Advisories** — the preferred channel:
   <https://github.com/davidslv/cce-ruby/security/advisories/new>
2. **Email** — davidslv.london@gmail.com

Please include a description, reproduction steps or a proof-of-concept, and the
affected version. This is a solo, best-effort project with no formal SLA (see
[`SUPPORT.md`](SUPPORT.md)); the maintainer will acknowledge reports as soon as
practically possible, work with you on a fix, and credit you in the release
notes unless you prefer to remain anonymous. Please allow reasonable time for a
fix before any public disclosure.
