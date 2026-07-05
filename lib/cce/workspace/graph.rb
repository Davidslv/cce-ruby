# WHY: The value of a workspace over N separate repos is knowing how members relate.
#      Level-1 relationships are cross-member dependency edges A→B, read from A's
#      declared manifests and matched against B's package/name (SPEC-V2.2 §5).
# WHAT: Cross-member edge construction + deterministic read/write of workspace-graph.json.
# RESPONSIBILITIES:
#   - Build edges A→B when a name A declares equals member B's package or name.
#   - Emit `{members, edges}` with edges sorted by (from, to, via), members listed.
#   - Persist to / load from `<root>/.cce/workspace-graph.json`.
#   - Deliberately NOT extract dependency names (Dependencies) or rank chunks.

require "json"
require "fileutils"
require_relative "dependencies"

module CCE
  module Workspace
    module Graph
      module_function

      # Absolute path to a root's workspace-graph.json.
      def path_for(root)
        File.join(Workspace.cce_dir(root), WORKSPACE_GRAPH_FILE)
      end

      # Build the cross-member graph for a manifest.
      # @return [Hash] { members: [names], edges: [{from:, to:, via:}] } (deterministic)
      def build(root, manifest)
        root = File.expand_path(root)
        by_dep = dep_index(manifest.members)
        edges = []
        manifest.members.each do |member|
          dir = File.join(root, member.path)
          Dependencies.extract(dir).each do |dep|
            target = by_dep[dep[:name]]
            next if target.nil? || target == member.name

            edges << { from: member.name, to: target, via: dep[:via] }
          end
        end
        {
          members: manifest.members.map(&:name),
          edges: edges.uniq.sort_by { |e| [e[:from], e[:to], e[:via]] }
        }
      end

      # Map every member's package name AND member name to its member id, so an
      # edge fires whether A declares B's package or B's bare name (§5).
      def dep_index(members)
        index = {}
        members.each do |m|
          index[m.package] ||= m.name
          index[m.name] ||= m.name
        end
        index
      end

      # Write the graph deterministically to `<root>/.cce/workspace-graph.json`.
      def write(root, graph)
        path = path_for(root)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, to_json(graph))
        path
      end

      # Deterministic JSON (stable key order, 2-space indent).
      def to_json(graph)
        ordered = {
          "members" => graph[:members],
          "edges" => graph[:edges].map { |e| { "from" => e[:from], "to" => e[:to], "via" => e[:via] } }
        }
        JSON.pretty_generate(ordered) + "\n"
      end

      # Load a graph from disk, or an empty graph when absent.
      # @return [Hash] { members:, edges: [{from:, to:, via:}] } with symbol keys
      def load(root)
        path = path_for(root)
        return { members: [], edges: [] } unless File.file?(path)

        data = JSON.parse(File.read(path))
        {
          members: Array(data["members"]),
          edges: Array(data["edges"]).map { |e| { from: e["from"], to: e["to"], via: e["via"] } }
        }
      end
    end
  end
end
