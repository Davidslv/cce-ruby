# WHY: Vector similarity alone misses exact identifier matches (a query for a
#      function name should surface that function). BM25 keyword scoring is the
#      lexical half of hybrid retrieval (SPEC §6.3).
# WHAT: An in-memory BM25 index (Lucene idf form) over chunk contents.
# RESPONSIBILITIES:
#   - Tokenize documents, compute term frequencies, |D|, avgdl, N, df.
#   - Score a set of unique query tokens with the exact BM25 formula.
#   - Return ranked, capped candidates and 0-based ranks; exclude zero-score docs.
#   - Deliberately NOT own fusion or final blending (that is the retriever).

require_relative "config"
require_relative "tokenizer"
require_relative "numeric_format"

module CCE
  class KeywordStore
    # @param docs [Array<Hash>] each { chunk_id:, content: }
    def initialize(docs)
      @doc_ids = []
      @tf = {}         # chunk_id => { token => freq }
      @len = {}        # chunk_id => |D|
      @df = Hash.new(0) # token => number of docs containing it
      total = 0
      docs.each do |d|
        id = d[:chunk_id]
        tokens = Tokenizer.tokenize(d[:content].to_s)
        freqs = Hash.new(0)
        tokens.each { |t| freqs[t] += 1 }
        @doc_ids << id
        @tf[id] = freqs
        @len[id] = tokens.length
        total += tokens.length
        freqs.each_key { |t| @df[t] += 1 }
      end
      @n = @doc_ids.length
      @avgdl = @n.zero? ? 0.0 : total.to_f / @n
    end

    attr_reader :avgdl

    def doc_count
      @n
    end

    # idf(q) = ln(1 + (N - n_q + 0.5)/(n_q + 0.5)) (non-negative Lucene form).
    def idf(token)
      nq = @df[token]
      Math.log(1 + (@n - nq + 0.5) / (nq + 0.5))
    end

    # BM25 score for each document that contains at least one query term.
    # @param query_tokens [Array<String>] the UNIQUE query tokens (set Q)
    # @return [Hash{String=>Float}] chunk_id => score (only positive scores)
    def scores(query_tokens)
      q = query_tokens.uniq
      k1 = Config::BM25_K1
      b = Config::BM25_B
      result = {}
      @doc_ids.each do |id|
        dl = @len[id]
        freqs = @tf[id]
        s = 0.0
        q.each do |t|
          nq = @df[t]
          next if nq.zero?

          f = freqs[t]
          next if f.zero?

          numerator = f * (k1 + 1)
          denominator = f + k1 * (1 - b + b * (dl.to_f / @avgdl))
          s += idf(t) * (numerator / denominator)
        end
        result[id] = s if s > 0
      end
      result
    end

    # Ranked candidates (desc by score, tie chunk_id asc), capped at `limit`.
    # @return [Array<Hash>] each { chunk_id:, score: }
    def candidates(query_tokens, limit:)
      ranked = NumericFormat.sort_by_score_desc(
        scores(query_tokens).map { |id, sc| { chunk_id: id, score: sc } },
        score: ->(x) { x[:score] },
        id: ->(x) { x[:chunk_id] }
      )
      ranked.first([limit, 0].max)
    end

    # 0-based rank map for candidates (chunk_id => frank).
    def ranks(query_tokens, limit:)
      map = {}
      candidates(query_tokens, limit: limit).each_with_index { |c, i| map[c[:chunk_id]] = i }
      map
    end
  end
end
