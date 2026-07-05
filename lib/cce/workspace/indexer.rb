# WHY: Federated storage is the second pillar (SPEC-V2.2 §4): every member is indexed
#      into its OWN `<member>/.cce/` exactly as a standalone repo, so isolation and
#      per-member secret scrubbing are preserved and a member store is byte-identical
#      to indexing that member alone. A workspace is only a manifest that federates them.
# WHAT: The workspace index orchestration over a manifest.
# RESPONSIBILITIES:
#   - Run the normal single-repo Indexer per member into its own store.
#   - Build and persist the cross-member dependency graph (§5).
#   - Return a per-member + totals summary for the CLI.
#   - Deliberately NOT own the chunk/embed pipeline (Indexer) or edge maths (Graph).

require_relative "../indexer"
require_relative "manifest"
require_relative "graph"
require_relative "../metrics_recorder"
require_relative "../metrics_event_log"

module CCE
  module Workspace
    module Indexer
      module_function

      # Index every member of the workspace rooted at `root` into its own store,
      # then build the cross-member graph.
      # @return [Hash] { root:, members: [{name, path, type, files, chunks, store_path}],
      #                  totals: { files:, chunks: }, graph:, graph_path: }
      def index(root, embedder: "hash", allow_secrets: false, record_metrics: true)
        root = File.expand_path(root)
        manifest = Manifest.load(root)

        members = manifest.members.map do |member|
          member_dir = File.join(root, member.path)
          store_path = Workspace.member_store_path(root, member)
          summary = CCE::Indexer.index(member_dir, store_path: store_path,
                                       embedder: embedder, allow_secrets: allow_secrets)
          record_member_index(store_path, summary, embedder) if record_metrics
          {
            name: member.name, path: member.path, type: member.type,
            files: summary[:files_indexed], chunks: summary[:total_chunks],
            store_path: store_path
          }
        end

        graph = Graph.build(root, manifest)
        graph_path = Graph.write(root, graph)

        {
          root: root,
          members: members,
          totals: {
            files: members.sum { |m| m[:files] },
            chunks: members.sum { |m| m[:chunks] }
          },
          graph: graph,
          graph_path: graph_path
        }
      end

      # Record a per-member `index` event next to the member's store, so the
      # workspace dashboard can federate it (§7). Best-effort.
      def record_member_index(store_path, summary, embedder)
        mpath = File.join(File.dirname(store_path), Metrics::FILE)
        Metrics::Recorder.new(log: Metrics::EventLog.new(mpath)).record_index(
          files_indexed: summary[:files_indexed],
          chunks: summary[:total_chunks],
          index_bytes: File.exist?(store_path) ? File.size(store_path) : 0,
          duration_ms: summary[:elapsed] * 1000.0,
          embedder: embedder.is_a?(String) ? embedder : embedder.name,
          full: true
        )
      rescue StandardError
        nil
      end
    end
  end
end
