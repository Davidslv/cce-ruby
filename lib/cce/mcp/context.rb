# WHY: The MCP tools must resolve the store exactly like the CLI, stay strictly
#      read-only and offline, degrade gracefully when there is no index, and warm
#      the local index from CCE Sync when (and only when) a remote is configured
#      (SPEC-MCP §2, "CCE MCP × CCE Sync"). Concentrating that policy here keeps
#      the tools and the JSON-RPC server thin and pure.
# WHAT: The per-session Context: it resolves single-repo vs workspace mode, loads
#       a Retriever on demand, records `search`/`feedback` metrics events (so the
#       dashboard sees agent usage), computes index status + sync freshness, and
#       best-effort auto-pulls the latest cached index on startup.
# RESPONSIBILITIES:
#   - Resolve dir/store/workspace to a store (or member set) like the CLI.
#   - search / record_feedback / index_status over that store (read-only).
#   - Soft sync dependency: warm_up! auto-pulls only when configured + enabled,
#     never blocking, never erroring (offline-first preserved).
#   - Deliberately NOT own the JSON-RPC framing (Server) or text formatting (Tools).

require "json"
require_relative "../indexer"
require_relative "../store"
require_relative "../metrics"
require_relative "../metrics_event_log"
require_relative "../metrics_recorder"
require_relative "../workspace"
require_relative "../sync"

module CCE
  module MCP
    class Context
      attr_reader :workspace, :root

      # @param dir [String,nil] project dir (cwd when nil); resolves <dir>/.cce/index.db
      # @param store [String,nil] explicit store path (wins over dir)
      # @param workspace [Boolean] federate a workspace of members (SPEC-V2.2)
      # @param home [String] HOME for sync config resolution (hermetic in tests)
      # @param clock / id_source injectable for deterministic query ids in tests
      def initialize(dir: nil, store: nil, workspace: false, home: Dir.home,
                     clock: Metrics::SystemClock.new, id_source: Metrics::RandomIdSource.new)
        @workspace = workspace
        @home = home
        @clock = clock
        @id_source = id_source
        @root = File.expand_path(dir || ".")
        @store_path = store ? File.expand_path(store) : MCP.default_store_for(@root)
      end

      # Best-effort startup warm-up (SPEC-MCP "CCE MCP × CCE Sync"). When a sync
      # remote is configured AND `sync.auto_pull` is on, pull the latest cached
      # index so the agent starts on fresh, team-shared context. Offline / absent
      # remote / any failure → serve whatever is local. NEVER blocks or raises:
      # the soft dependency must never degrade MCP below "use the local index".
      # @return [Symbol] :pulled, :skipped, or :offline (diagnostic only)
      def warm_up!
        cfg = Sync::Config.load(project_root, home: @home)
        return :skipped unless cfg.configured? && cfg.auto_pull?

        Sync::Commands.new(project_dir: project_root, home: @home).pull(latest: true)
        :pulled
      rescue StandardError
        :offline
      end

      # ---- search --------------------------------------------------------------

      # Run a retrieval and record a `search` metrics event (SPEC-MCP §Tools.1).
      # @return [Hash] { results: Array<Hash>, query_id: String, indexed: Boolean }
      def search(query, top_k:, graph_enabled:, package: nil)
        return { results: [], query_id: nil, indexed: false } unless indexed?

        @workspace ? workspace_search(query, top_k, graph_enabled, package)
                   : single_search(query, top_k, graph_enabled)
      end

      # ---- feedback ------------------------------------------------------------

      # Append a `feedback` event tied to a prior search's query_id (SPEC-MCP §Tools.3).
      def record_feedback(query_id:, helpful:, note: "")
        recorder(metrics_path).record_feedback(target_id: query_id, helpful: helpful, note: note)
      end

      # ---- status --------------------------------------------------------------

      # A structured freshness report (SPEC-MCP §Tools.2): counts, per-language and
      # per-kind breakdown, store path, last-indexed time, and the sync source/
      # sha/behind-remote picture. Never raises on a missing index.
      def index_status
        base = { workspace: @workspace, indexed: indexed?, store_path: display_store_path }
        base.merge!(@workspace ? workspace_status : single_status) if indexed?
        base[:sync] = sync_status
        base
      end

      def indexed?
        @workspace ? workspace_indexed? : File.exist?(@store_path)
      end

      # The directory that owns .cce/ (config, metrics, sync marker) for this session.
      def project_root
        @root
      end

      private

      # ---- single-repo ---------------------------------------------------------

      def single_search(query, top_k, graph_enabled)
        retriever = Indexer.retriever_from_store(@store_path)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        results = retriever.search(query, top_k: top_k, graph_enabled: graph_enabled)
        latency_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        event = record_search_event(results, query, top_k, graph_enabled)
        { results: results, query_id: event && event["id"], indexed: true }
      end

      def record_search_event(results, query, top_k, graph_enabled)
        file_tokens, embedder = store_context(@store_path)
        recorder(metrics_path).record_search(
          query: query, top_k: top_k, graph_enabled: graph_enabled, embedder: embedder,
          results: results, file_token_counts: file_tokens, latency_ms: 0.0, source: "mcp"
        )
      end

      def single_status
        s = Store.open(@store_path)
        begin
          chunks = s.chunks
          {
            chunk_count: chunks.length,
            file_count: chunks.map(&:file_path).uniq.length,
            by_language: chunks.map(&:language).tally.sort.to_h,
            by_kind: chunks.map(&:kind).tally.sort.to_h,
            embedder: s.embedder_name,
            last_indexed: last_indexed(@store_path)
          }
        ensure
          s.close
        end
      end

      # ---- workspace -----------------------------------------------------------

      def workspace_search(query, top_k, graph_enabled, package)
        manifest = Workspace::Manifest.load(@root)
        packages = package.to_s.strip.empty? ? nil : [package.strip]
        members = Workspace::Federation.scope_members(manifest, packages)
        loaded = Workspace::Federation.load_members(@root, members)
        cross_edges = Workspace::Graph.load(@root)[:edges]
        retriever = Workspace::FederatedRetriever.new(members: loaded, cross_edges: cross_edges)
        results = retriever.search(query, top_k: top_k, graph_enabled: graph_enabled)
        event = record_workspace_search_event(results, query, top_k, graph_enabled, members, package)
        { results: results, query_id: event && event["id"], indexed: true }
      end

      def record_workspace_search_event(results, query, top_k, graph_enabled, members, package)
        recorder(metrics_path).record_search(
          query: query, top_k: top_k, graph_enabled: graph_enabled, embedder: "hash",
          results: results, file_token_counts: workspace_file_tokens(members), latency_ms: 0.0,
          source: "mcp", package: package
        )
      end

      # Merge every in-scope member's whole-file token counts for the baseline.
      def workspace_file_tokens(members)
        merged = {}
        members.each do |m|
          path = Workspace.member_store_path(@root, m)
          next unless File.exist?(path)

          f, = store_context(path)
          merged.merge!(f)
        end
        merged
      end

      def workspace_status
        manifest = Workspace::Manifest.load(@root)
        data = Workspace::Stats.compute(@root, manifest)
        {
          chunk_count: data[:totals][:chunks],
          file_count: data[:totals][:files],
          members: data[:members],
          edges: data[:edges]
        }
      end

      def workspace_indexed?
        return false unless Workspace::Manifest.exist?(@root)

        manifest = Workspace::Manifest.load(@root)
        manifest.members.any? { |m| File.exist?(Workspace.member_store_path(@root, m)) }
      rescue Workspace::Error
        false
      end

      # ---- sync freshness (soft, best-effort) ----------------------------------

      # The index's provenance for `index_status`: whether it came from a sync
      # pull (marker present) or a local index, its sha, and whether the local
      # cache is behind the remote's latest. Remote contact is guarded so an
      # offline server still answers (remote_latest => "(unreachable)").
      def sync_status
        cfg = Sync::Config.load(project_root, home: @home)
        marker = read_sync_marker
        base = {
          configured: cfg.configured?,
          auto_pull: cfg.auto_pull?,
          source: marker ? "sync-pull" : "local",
          sha: marker && marker["sha"]
        }
        base.merge!(remote_freshness(marker)) if cfg.configured?
        base
      end

      def remote_freshness(marker)
        s = Sync::Commands.new(project_dir: project_root, home: @home).status
        latest = s[:remote_latest]
        behind = latest.is_a?(String) && marker && marker["sha"] != latest
        { remote_latest: latest, behind_remote: behind }
      rescue StandardError
        { remote_latest: :unreachable, behind_remote: nil }
      end

      def read_sync_marker
        path = File.join(project_root, ".cce", Sync::Commands::MARKER)
        return nil unless File.file?(path)

        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end

      # ---- shared helpers ------------------------------------------------------

      def recorder(path)
        Metrics::Recorder.new(
          log: Metrics::EventLog.new(path), clock: @clock, id_source: @id_source, enabled: true
        )
      end

      # Metrics log lives beside the store (single) or under <root>/.cce/ (workspace),
      # so `cce dashboard` picks up agent searches (SPEC-MCP §Observability).
      def metrics_path
        if @workspace
          File.join(@root, ".cce", Metrics::FILE)
        else
          File.join(File.dirname(@store_path), Metrics::FILE)
        end
      end

      def store_context(store_path)
        s = Store.open(store_path)
        begin
          [s.file_token_counts, s.embedder_name]
        ensure
          s.close
        end
      rescue StandardError
        [{}, "hash"]
      end

      def last_indexed(store_path)
        File.exist?(store_path) ? File.mtime(store_path).utc.strftime("%Y-%m-%dT%H:%M:%SZ") : nil
      end

      def display_store_path
        @workspace ? File.join(@root, ".cce") : @store_path
      end
    end
  end
end
