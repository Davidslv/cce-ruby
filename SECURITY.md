# Security Policy

## Supported versions

cce-ruby follows [Semantic Versioning](https://semver.org/). Security fixes are
provided for the current minor series only.

| Version | Supported |
|---|---|
| 1.1.x   | ✅ |
| 1.0.x   | ✅ |
| < 1.0   | ❌ |

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
- **No network calls by default.** The default `hash` embedder is fully local
  and deterministic. The tool makes **no** outbound connections during normal
  `index`/`search`/`stats`/`conformance` operation. (A first run may download
  tree-sitter grammar libraries into a local cache; after that it is offline.)
- **The only optional network path is opt-in.** Passing `--embedder ollama`
  makes CCE talk to a local [Ollama](https://ollama.com/) server over
  **localhost HTTP** (`http://localhost:11434`). This is opt-in, localhost-only,
  and fails gracefully with a clear message if the server is unreachable. No
  other host is ever contacted.
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
