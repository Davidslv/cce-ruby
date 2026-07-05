# WHY: `cce init` is the plug-and-play on-ramp (SPEC-MCP §cce init): one command
#      that ensures an index, wires the editor's MCP config, and drops a CLAUDE.md
#      block steering the agent to prefer context_search over Read/Grep — so a
#      user goes from clone to "the agent searches my code" without hand-editing
#      JSON. It must be idempotent (safe to re-run) and offline-first.
# WHAT: The init orchestrator: ensure index (local or via sync pull), merge a
#       `.mcp.json` server entry, merge a bounded CLAUDE.md block, print next steps.
# RESPONSIBILITIES:
#   - Ensure an index exists (sync pull when --remote/configured, else local index;
#     workspace-aware when a workspace.yml / members are present).
#   - Idempotently merge the `cce` entry into <dir>/.mcp.json (no duplicates).
#   - Idempotently merge the CCE block into <dir>/CLAUDE.md (stable markers).
#   - Deliberately NOT own the server (Server) or the tools (Tools).

require "json"
require "fileutils"
require_relative "../indexer"
require_relative "../workspace"
require_relative "../sync"

module CCE
  module MCP
    module Init
      module_function

      MCP_FILE   = ".mcp.json"
      CLAUDE_FILE = "CLAUDE.md"
      BEGIN_MARKER = "<!-- BEGIN CCE MCP (managed by `cce init`) -->"
      END_MARKER   = "<!-- END CCE MCP -->"

      CLAUDE_BODY = <<~MD.freeze
        ## Code search — use CCE first

        This project is indexed by CCE and exposed as the MCP tool **`context_search`**.

        - PREFER `context_search` over reading or grepping files to locate functions,
          understand behaviour, or answer "where is X / how does Y work". It returns the
          most relevant code chunks (file:line + kind) from a hybrid vector + BM25 index,
          so you don't pay tokens for whole files.
        - Reserve file reads for opening a specific path `context_search` points you to.
        - Use `index_status` to check freshness, and `record_feedback` to rate a result.
      MD

      # Run `cce init`. Returns a result hash the CLI formats into "next steps".
      # @param dir [String] project dir (default ".")
      # @param agent [String] editor target (v1: "claude")
      # @param remote [String,nil] sync remote URL — pull the CI-built index instead
      #   of indexing locally
      # @param force [Boolean] re-index even if an index already exists
      # @param home [String] HOME for sync config (hermetic in tests)
      def run(dir: ".", agent: "claude", remote: nil, force: false, home: Dir.home)
        root = File.expand_path(dir)
        raise Error, "no such directory: #{dir}" unless File.directory?(root)
        raise Error, "unsupported --agent '#{agent}' (v1 supports: claude)" unless agent == "claude"

        workspace = workspace?(root)
        index = ensure_index(root, remote: remote, force: force, workspace: workspace, home: home)
        mcp_path = write_mcp_json(root, workspace: workspace)
        claude_path = write_claude_md(root)

        {
          dir: root, workspace: workspace, agent: agent,
          index: index, mcp_path: mcp_path, claude_path: claude_path
        }
      end

      # ---- ensure index --------------------------------------------------------

      def ensure_index(root, remote:, force:, workspace:, home:)
        cfg = Sync::Config.load(root, home: home)
        if remote || cfg.configured?
          ensure_via_sync(root, remote: remote, home: home)
        else
          ensure_local_index(root, force: force, workspace: workspace)
        end
      end

      # Configure the remote (if newly given), enable auto_pull, and pull the
      # CI-built index. The pull lazily clones the remote, so no separate `sync
      # init` step is needed. Best-effort: an unreachable remote falls back to a
      # local index so init never leaves the project un-indexed (offline-first).
      def ensure_via_sync(root, remote:, home:)
        Sync::Config.write_project(root, remote: remote, lfs: true, auto_pull: true) if remote
        res = Sync::Commands.new(project_dir: root, home: home).pull(latest: true)
        { mode: :sync, sha: res[:sha], chunk_count: res[:chunk_count] }
      rescue Sync::Error, Sync::Git::GitError => e
        { mode: :sync_failed, error: e.message,
          fallback: ensure_local_index(root, force: false, workspace: workspace?(root)) }
      end

      def ensure_local_index(root, force:, workspace:)
        return ensure_workspace_index(root, force: force) if workspace

        store = MCP.default_store_for(root)
        if File.exist?(store) && !force
          { mode: :local, reused: true, store: store }
        else
          summary = Indexer.index(root, store_path: store, embedder: "hash")
          { mode: :local, reused: false, store: store,
            files: summary[:files_indexed], chunks: summary[:total_chunks] }
        end
      end

      def ensure_workspace_index(root, force:)
        # Ensure a manifest exists (detect on first init), then index members.
        Workspace::Manifest.detect(root).write(root) unless Workspace::Manifest.exist?(root)
        manifest = Workspace::Manifest.load(root)
        already = manifest.members.any? { |m| File.exist?(Workspace.member_store_path(root, m)) }
        if already && !force
          { mode: :workspace, reused: true }
        else
          summary = Workspace::Indexer.index(root, embedder: "hash", record_metrics: false)
          { mode: :workspace, reused: false,
            members: summary[:members].length, chunks: summary[:totals][:chunks] }
        end
      end

      # ---- .mcp.json -----------------------------------------------------------

      # Merge the `cce` server entry into <dir>/.mcp.json, preserving any other
      # servers and re-running cleanly (idempotent — no duplicate entries).
      def write_mcp_json(root, workspace:)
        path = File.join(root, MCP_FILE)
        doc = read_json(path) || {}
        doc = {} unless doc.is_a?(Hash)
        servers = doc["mcpServers"].is_a?(Hash) ? doc["mcpServers"] : {}
        servers["cce"] = { "command" => "cce", "args" => server_args(workspace) }
        doc["mcpServers"] = servers
        File.write(path, "#{JSON.pretty_generate(doc)}\n")
        path
      end

      def server_args(workspace)
        workspace ? ["mcp", "--workspace"] : ["mcp", "--dir", "."]
      end

      # ---- CLAUDE.md -----------------------------------------------------------

      # Merge the bounded CCE block into <dir>/CLAUDE.md. If the markers are
      # present the block is replaced in place; otherwise it is appended. Re-running
      # never duplicates the block.
      def write_claude_md(root)
        path = File.join(root, CLAUDE_FILE)
        existing = File.file?(path) ? File.read(path) : ""
        block = "#{BEGIN_MARKER}\n#{CLAUDE_BODY}#{END_MARKER}\n"
        updated = replace_or_append_block(existing, block)
        File.write(path, updated)
        path
      end

      def replace_or_append_block(existing, block)
        if existing.include?(BEGIN_MARKER) && existing.include?(END_MARKER)
          existing.sub(/#{Regexp.escape(BEGIN_MARKER)}.*?#{Regexp.escape(END_MARKER)}\n?/m, block)
        elsif existing.empty?
          block
        else
          "#{existing.chomp}\n\n#{block}"
        end
      end

      # ---- helpers -------------------------------------------------------------

      def workspace?(root)
        return true if Workspace::Manifest.exist?(root)

        Workspace::Detector.detect(root).length > 1
      rescue StandardError
        false
      end

      def read_json(path)
        return nil unless File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end
    end
  end
end
