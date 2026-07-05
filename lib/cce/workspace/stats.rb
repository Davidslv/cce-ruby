# WHY: Operators want one glance at the whole ecosystem: how big each member is and
#      how the members relate (SPEC-V2.2 §7). Stats reads each member's own store
#      (federated storage) and the manifest-derived edges.
# WHAT: A pure per-member + totals + edges computation for `cce stats --workspace`.
# RESPONSIBILITIES:
#   - Report per member: files, chunks, by-kind (0/false when not yet indexed).
#   - Sum workspace totals and surface the cross-member edges.
#   - Deliberately NOT format output (CLI) or mutate anything (read-only).

require_relative "../store"
require_relative "manifest"
require_relative "graph"

module CCE
  module Workspace
    module Stats
      module_function

      # @return [Hash] { members: [..], totals: { files:, chunks: }, edges: [..] }
      def compute(root, manifest)
        root = File.expand_path(root)
        members = manifest.members.map { |m| member_stats(root, m) }
        {
          members: members,
          totals: {
            files: members.sum { |m| m[:files] },
            chunks: members.sum { |m| m[:chunks] }
          },
          edges: Graph.build(root, manifest)[:edges]
        }
      end

      def member_stats(root, member)
        store_path = Workspace.member_store_path(root, member)
        base = { name: member.name, path: member.path, type: member.type }
        return base.merge(indexed: false, files: 0, chunks: 0, by_kind: {}) unless File.exist?(store_path)

        store = Store.open(store_path)
        begin
          chunks = store.chunks
          base.merge(
            indexed: true,
            files: chunks.map(&:file_path).uniq.length,
            chunks: chunks.length,
            by_kind: chunks.map(&:kind).tally
          )
        ensure
          store.close
        end
      end
    end
  end
end
