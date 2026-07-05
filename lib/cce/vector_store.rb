# WHY: The engine needs semantic candidates for a query. Corpora are small, so
#      the spec mandates exact brute-force cosine rather than an ANN index
#      (SPEC §1.2, §6.2) — simple and correct.
# WHAT: An in-memory store of chunk vectors with cosine search.
# RESPONSIBILITIES:
#   - Hold each chunk's normalised embedding keyed by chunk_id.
#   - Rank all chunks by cosine to a query (desc, tie chunk_id asc), cap to limit.
#   - Provide cosine of the query to any specific chunk (for BM25-only candidates).
#   - Deliberately NOT own fusion, confidence, or persistence.

require_relative "embedder"
require_relative "numeric_format"

module CCE
  class VectorStore
    # @param entries [Array<Hash>] each { chunk_id:, vector: }
    def initialize(entries)
      @vectors = {}
      entries.each { |e| @vectors[e[:chunk_id]] = e[:vector] }
    end

    def cosine_to(chunk_id, query_vector)
      v = @vectors[chunk_id]
      return 0.0 unless v

      Embedder.cosine(v, query_vector)
    end

    # All chunks with their cosine to the query, ranked and capped.
    # @return [Array<Hash>] each { chunk_id:, cosine:, distance: }
    def candidates(query_vector, limit:)
      scored = @vectors.map do |id, v|
        c = Embedder.cosine(v, query_vector)
        { chunk_id: id, cosine: c, distance: 1.0 - c }
      end
      ranked = NumericFormat.sort_by_score_desc(
        scored, score: ->(x) { x[:cosine] }, id: ->(x) { x[:chunk_id] }
      )
      ranked.first([limit, 1].max)
    end

    # 0-based vrank map for the top candidates (chunk_id => vrank).
    def ranks(query_vector, limit:)
      map = {}
      candidates(query_vector, limit: limit).each_with_index { |c, i| map[c[:chunk_id]] = i }
      map
    end
  end
end
