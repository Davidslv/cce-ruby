# CCE MCP — use CCE from your agent (Claude Code)

CCE ships an **MCP (Model Context Protocol) server** so an agent — Claude Code,
Cursor, … — calls CCE as a **first-class tool it auto-invokes**, instead of you
hoping it shells out to `cce search`. It answers two questions directly:

1. **"How do I make my agent use CCE?"** → a real MCP tool (`context_search`)
   plus a `CLAUDE.md` block steering the model to prefer it over Read/Grep.
2. **"How do I know it used it?"** → every search is a visible tool call **and**
   is logged to `.cce/metrics.jsonl`, so `cce dashboard` shows the agent's
   queries and token savings.

This is [SPEC-MCP](../SPEC-MCP.md) (v2.4), additive on top of the engine (v1.0),
workspaces (v2.2), and sync (v2.3). The Ruby and Rust engines expose the **same
tool names, input schemas, and output shape** — the cross-language contract.

---

## Quick start

```
$ cce init            # in your project root
CCE init — project at /path/to/project
  index:    indexed 2 files (5 chunks)
  .mcp.json: /path/to/project/.mcp.json
  CLAUDE.md: /path/to/project/CLAUDE.md

Next steps:
  1. Restart your editor (Claude Code) so it loads the `cce` MCP server.
  2. Ask a question about this codebase — the agent will call context_search.
  3. Confirm it was used: `cce dashboard` shows the agent's queries.
```

`cce init`:

- **Ensures an index** — runs `cce index` (or `cce index --workspace` when it
  detects a workspace), or, with `--remote`, pulls a CI-built index via CCE Sync.
- Writes/merges **`.mcp.json`** with a `cce` server entry (idempotent):
  ```json
  { "mcpServers": { "cce": { "command": "cce", "args": ["mcp", "--dir", "."] } } }
  ```
  (a workspace gets `"args": ["mcp", "--workspace"]`).
- Writes/merges a **bounded `CLAUDE.md` block** (between stable marker comments)
  telling the agent to prefer `context_search`.

Re-running `cce init` never duplicates the server entry or the CLAUDE.md block.

Then **restart Claude Code**. It launches `cce mcp` as a subprocess and the three
tools appear. Ask *"where is password hashing?"* and the agent calls
`context_search` instead of grepping.

## The server: `cce mcp`

`cce mcp` speaks **MCP over stdio, JSON-RPC 2.0**. You normally never run it by
hand — the editor does, per `.mcp.json`. It is **read-only** (loads the index,
never mutates source or the store) and **offline** (no network, unless the index
was built with the optional Ollama embedder).

```
cce mcp [--dir DIR | --store PATH] [--workspace]
```

Handshake + methods: `initialize` → `{ protocolVersion, capabilities:{tools:{}},
serverInfo:{name:"cce",version} }`; `notifications/initialized`; `tools/list`;
`tools/call`; `ping`. The pinned protocol revision is **`2025-06-18`**.

**Missing index?** The tools still respond — `context_search` returns a friendly
*"run `cce index`"* message and `index_status` reports "not indexed". No crash.

## The three tools (cross-language contract)

### `context_search` — the headline

> PREFERRED tool for any question about THIS project's code. Use INSTEAD OF
> reading or grepping files to locate functions, understand behaviour, or answer
> "where is X / how does Y work". Returns the most relevant code chunks
> (file:line + kind) from a hybrid vector + BM25 index, so you don't pay tokens
> for whole files. Reserve file reads for opening a specific path this tool
> points you to.

Input: `{ query (required), top_k=8, package?, no_graph=false, max_tokens? }`.
Output: ranked chunks, one header line (`#. [score] file:line (chunk_type/kind)`)
per result followed by the chunk body, plus a `query_id` for feedback. Every call
**logs a `search` event** to `.cce/metrics.jsonl`.

### `index_status`

Input: `{}`. Reports chunk/file counts, per-language and per-kind breakdown, the
store path, last-indexed time, and — when CCE Sync is configured — the index's
source (local vs pulled), its `sha`, and whether it is behind the remote.

### `record_feedback`

Input: `{ query_id (required), helpful (required), note? }`. Appends a `feedback`
event to `.cce/metrics.jsonl`, closing the quality loop into the dashboard.

## How to confirm the agent used it

Two independent signals:

1. **The editor's tool-call log** shows a `context_search` call for your question.
2. **`cce dashboard`** (or `cce dashboard --workspace`) reads `.cce/metrics.jsonl`
   and shows the agent's queries, counts, and token savings — proof of use *and*
   value. Each `context_search` writes one `search` event there, exactly like the
   CLI `cce search` path.

## Freshness with CCE Sync (soft dependency)

The MCP server is the biggest beneficiary of [CCE Sync](sync.md): Sync keeps the
agent's context fresh **without the agent or the developer paying local indexing
cost**.

- `cce init --remote <sync-url>` pulls the CI-built index (seconds, not a full
  re-index), enables `sync.auto_pull`, then wires the editor. Restart → the agent
  searches fresh, team-shared context.
- On startup, if a sync remote is configured and `sync.auto_pull` is on, `cce mcp`
  does a **best-effort `sync pull --latest`** to warm the local index before
  serving. Offline / no remote → it serves whatever is local. This **never blocks
  or errors** — offline-first is preserved.
- `index_status` reports the pulled `sha` and whether you are behind the remote.

**Soft dependency:** MCP never hard-requires Sync. With no remote configured it
uses the local index exactly as specified — a failed or absent Sync never
degrades MCP below "use the local index".

## Security

The server only ever returns what is already in the store, which is **redacted at
index time** (SPEC-V2.1 secret protection). Nothing new to scrub. It is read-only
and offline. See [SECURITY.md](../SECURITY.md).

## Other editors

v1 targets **Claude Code**. Cursor (`.cursor/mcp.json`), VS Code
(`.vscode/mcp.json`), and Codex (`~/.codex/config.toml`) are a documented
fast-follow behind `cce init --agent <name>`.
