# WHY: Federated search is the payoff (SPEC-V2.2 §6): a workspace search is DEFINED
#      to equal one standard §6 retrieval run over the union of the in-scope members'
#      stored chunks. Keeping it literally that — a single Retriever over the
#      concatenated chunks — makes the "federation == union-index" equivalence exact,
#      and layers cross-member graph hops on top without disturbing it.
# WHAT: In-scope member resolution/loading + the FederatedRetriever.
# RESPONSIBILITIES:
#   - Resolve `--package` scope (error on unknown name) and load member stores.
#   - Run the standard §6 pipeline once over the union, tagging each result's member.
#   - Add cross-member graph expansion: a top result in A pulls chunks from B via an
#     A→B edge (bounded by GRAPH_MAX_BONUS_MEMBERS / GRAPH_BONUS_MEMBER_CHUNKS).
#   - Deliberately NOT own edge extraction (Graph) or ranking maths (Retriever).

require "set"
require_relative "../store"
require_relative "../retriever"
require_relative "../embedder"
require_relative "../numeric_format"

module CCE
  module Workspace
    module Federation
      module_function

      # Resolve in-scope members. `packages` nil/empty => all members; otherwise the
      # named members (raising Error on any unknown NAME).
      def scope_members(manifest, packages)
        return manifest.members if packages.nil? || packages.empty?

        known = manifest.members.map(&:name)
        unknown = packages - known
        raise Error, "unknown package(s): #{unknown.sort.uniq.join(', ')}" unless unknown.empty?

        manifest.members.select { |m| packages.include?(m.name) }
      end

      # Load each in-scope member's store into memory. Members without a store yet
      # are skipped (a workspace search federates whatever stores exist, §4).
      # @return [Array<Hash>] each { name:, chunks:, vectors:, file_imports: }
      def load_members(root, members)
        root = File.expand_path(root)
        members.filter_map do |member|
          store_path = Workspace.member_store_path(root, member)
          next unless File.exist?(store_path)

          store = Store.open(store_path)
          begin
            { name: member.name, chunks: store.chunks,
              vectors: store.vectors, file_imports: store.file_imports }
          ensure
            store.close
          end
        end
      end
    end

    # A retriever over the union of several members' stored chunks (SPEC-V2.2 §6).
    class FederatedRetriever
      # @param members [Array<Hash>] { name:, chunks:, vectors:, file_imports: }
      # @param cross_edges [Array<Hash>] { from:, to:, via: } cross-member edges
      # @param embedder [#embed] query embedder (same backend used at index time)
      def initialize(members:, cross_edges: [], embedder: HashEmbedder.new)
        @embedder = embedder
        @cross_edges = cross_edges
        @members = {}
        @member_of = {}
        union_chunks = []
        union_vectors = {}
        union_imports = {}

        members.sort_by { |m| m[:name] }.each do |m|
          by_id = {}
          m[:chunks].each do |c|
            by_id[c.chunk_id] = c
            @member_of[c.chunk_id] ||= m[:name]
            union_chunks << c
            union_vectors[c.chunk_id] = m[:vectors][c.chunk_id]
          end
          m[:file_imports].each { |fp, mods| union_imports[fp] ||= mods }
          @members[m[:name]] = { chunks: m[:chunks], vectors: m[:vectors], by_id: by_id }
        end

        @retriever = Retriever.new(union_chunks, embedder: @embedder,
                                   vectors: union_vectors, file_imports: union_imports)
      end

      # Federated search. The base list is exactly a standard §6 retrieval over the
      # union (the correctness anchor); with the graph on, cross-member hops append.
      def search(query, top_k: Config::DEFAULT_TOP_K, graph_enabled: true)
        base = @retriever.search(query, top_k: top_k, graph_enabled: graph_enabled)
        results = base.map { |r| tag(r, @member_of[r[:chunk_id]]) }
        if graph_enabled && !@cross_edges.empty?
          cross_member_expand(results, query).each_with_index do |b, i|
            results << b.merge(rank: base.length + i + 1)
          end
        end
        results
      end

      private

      def tag(result, member)
        result.merge(member: member, package: member)
      end

      # Cross-member expansion (§6.3): for a top result in member A, an A→B edge pulls
      # up to GRAPH_BONUS_MEMBER_CHUNKS chunks from B, bounded by GRAPH_MAX_BONUS_MEMBERS
      # distinct target members. Scored exactly as SPEC §6.7.
      def cross_member_expand(results, query)
        qv = @embedder.embed(query)
        seen = results.map { |r| span_of(r) }.to_set
        expanded = []
        bonus = []
        results.each do |r|
          break if expanded.length >= GRAPH_MAX_BONUS_MEMBERS

          edges_from(r[:member]).each do |edge|
            break if expanded.length >= GRAPH_MAX_BONUS_MEMBERS

            to = edge[:to]
            next if expanded.include?(to)

            member = @members[to]
            next unless member

            top_chunks(member, qv).each do |sc|
              span = [to, sc[:chunk].file_path, sc[:chunk].start_line, sc[:chunk].end_line]
              next if seen.include?(span)

              seen << span
              score = [0.0, sc[:cosine]].max * Config::GRAPH_BONUS_CHUNK_SCALE
              bonus << bonus_result(sc[:chunk], to, score)
            end
            expanded << to
          end
        end
        bonus
      end

      def edges_from(member)
        @cross_edges.select { |e| e[:from] == member }.sort_by { |e| [e[:to], e[:via]] }
      end

      def top_chunks(member, qv)
        scored = member[:chunks].map do |c|
          { chunk: c, cosine: Embedder.cosine(member[:vectors][c.chunk_id], qv) }
        end
        NumericFormat.sort_by_score_desc(
          scored, score: ->(x) { x[:cosine] }, id: ->(x) { x[:chunk].chunk_id }
        ).first(GRAPH_BONUS_MEMBER_CHUNKS)
      end

      def span_of(result)
        [result[:member], result[:file_path], result[:start_line], result[:end_line]]
      end

      def bonus_result(chunk, member, score)
        {
          rank: nil, member: member, package: member, chunk_id: chunk.chunk_id,
          file_path: chunk.file_path, start_line: chunk.start_line, end_line: chunk.end_line,
          chunk_type: chunk.chunk_type, kind: chunk.kind, language: chunk.language,
          token_count: chunk.token_count, content: chunk.content, score: score
        }
      end
    end
  end
end
