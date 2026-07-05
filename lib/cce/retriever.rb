# WHY: Neither vector similarity nor keyword matching alone gives good code
#      search. The retriever is the hybrid pipeline that fuses them and shapes
#      the final ranking — the product's core value (SPEC §6).
# WHAT: Query intent classification, vector + BM25 candidate generation, RRF
#       fusion, confidence blending, path penalty, per-file diversity cap, and
#       optional import-graph expansion.
# RESPONSIBILITIES:
#   - Own the exact ordering of the retrieval pipeline and its constants.
#   - Produce a deterministic, rounded, tie-broken result list.
#   - Deliberately NOT own persistence (Store) or embedding maths (Embedder).

require "set"
require_relative "config"
require_relative "tokenizer"
require_relative "embedder"
require_relative "vector_store"
require_relative "keyword_store"
require_relative "graph_store"
require_relative "numeric_format"

module CCE
  class Retriever
    include Config

    CODE_WORDS = /\b(?:function|class|method|def)\b/
    EXT_TOKEN  = /\.(?:py|js|jsx|ts|go|rb|rs|java)\b/
    WHERE_IS   = /where is /
    FIND_FN    = /find .* function/
    DEFINED    = /.* defined/

    # @param chunks [Array<Chunk>] the corpus
    # @param embedder [#embed] query embedder (same backend used at index time)
    # @param vectors [Hash,nil] chunk_id => vector (embedded lazily if nil)
    # @param file_imports [Hash] file_path => [module names] for the graph
    def initialize(chunks, embedder:, vectors: nil, file_imports: {})
      @embedder = embedder
      @chunks_by_id = {}
      @chunks_by_file = Hash.new { |h, k| h[k] = [] }
      @lower_content = {}
      vecs = {}

      chunks.each do |c|
        @chunks_by_id[c.chunk_id] = c
        @chunks_by_file[c.file_path] << c
        @lower_content[c.chunk_id] = ascii_downcase(c.content)
        vecs[c.chunk_id] = vectors ? vectors[c.chunk_id] : embedder.embed(c.content)
      end

      @vector_store = VectorStore.new(vecs.map { |id, v| { chunk_id: id, vector: v } })
      @keyword_store = KeywordStore.new(
        chunks.map { |c| { chunk_id: c.chunk_id, content: c.content } }
      )
      @graph_store = GraphStore.new(file_imports, @chunks_by_file.keys)
    end

    # ---- Intent (SPEC §6.1) --------------------------------------------------

    def self.classify_intent(query)
      lc = ascii_downcase(query.to_s)
      code = lc.match?(CODE_WORDS) || lc.match?(EXT_TOKEN) ||
             lc.match?(WHERE_IS) || lc.match?(FIND_FN) || lc.match?(DEFINED)
      code ? :code_lookup : :general
    end

    def self.fts_weight(intent)
      intent == :code_lookup ? Config::FTS_BOOST_CODE_LOOKUP : 1.0
    end

    def self.ascii_downcase(str)
      str.b.gsub(/[A-Z]/) { |ch| (ch.ord + 32).chr }.force_encoding(Encoding::UTF_8)
    end

    # ---- RRF (SPEC §6.4) -----------------------------------------------------

    def self.rrf_value(vrank, frank, fts_weight)
      v = vrank.nil? ? 0.0 : 1.0 / (Config::RRF_K + vrank)
      f = frank.nil? ? 0.0 : fts_weight * (1.0 / (Config::RRF_K + frank))
      v + f
    end

    # ---- Main entry ----------------------------------------------------------

    # @return [Array<Hash>] ranked results (each carries :score and chunk fields)
    def search(query, top_k: Config::DEFAULT_TOP_K, graph_enabled: true)
      q_tokens = Tokenizer.tokenize(query)
      return [] if q_tokens.empty?

      intent = self.class.classify_intent(query)
      fts_w = self.class.fts_weight(intent)
      qv = @embedder.embed(query)
      cand_limit = [top_k * Config::CANDIDATE_MULTIPLIER, 1].max

      vranks = @vector_store.ranks(qv, limit: cand_limit)
      unique_q = q_tokens.uniq
      franks = @keyword_store.ranks(unique_q, limit: cand_limit)

      candidate_ids = (vranks.keys + franks.keys).uniq
      file_hints = extract_file_hints(query)

      rrf = {}
      candidate_ids.each { |id| rrf[id] = self.class.rrf_value(vranks[id], franks[id], fts_w) }
      max_rrf = rrf.values.max || 0.0

      scored = candidate_ids.map do |id|
        norm_rrf = max_rrf.zero? ? 0.0 : rrf[id] / max_rrf
        conf = confidence(id, qv, unique_q, file_hints)
        final = blend(id, conf, norm_rrf)
        { chunk: @chunks_by_id[id], score: final }
      end

      ranked = NumericFormat.sort_by_score_desc(
        scored, score: ->(x) { x[:score] }, id: ->(x) { x[:chunk].chunk_id }
      )

      main = apply_diversity(ranked, top_k)
      results = main.each_with_index.map { |x, i| to_result(x[:chunk], x[:score], i + 1) }

      if graph_enabled
        bonus = expand_graph(results, qv)
        bonus.each_with_index { |b, i| results << to_result(b[:chunk], b[:score], results.length + 1) }
      end

      results
    end

    private

    # ---- Confidence (SPEC §6.5) ---------------------------------------------

    def confidence(id, qv, unique_q, file_hints)
      distance = 1.0 - @vector_store.cosine_to(id, qv)
      normalized = [[distance / 2.0, 0.0].max, 1.0].min
      vector_score = 1.0 - normalized

      keyword_distance = keyword_hit?(id, unique_q, file_hints) ? 0 : 2
      keyword_score = [0.0, 1.0 - keyword_distance / 5.0].max
      recency_score = 0.0

      Config::W_VECTOR * vector_score +
        Config::W_KEYWORD * keyword_score +
        Config::W_RECENCY * recency_score
    end

    def keyword_hit?(id, unique_q, file_hints)
      content = @lower_content[id]
      return true if unique_q.any? { |t| content.include?(t) }

      path = @chunks_by_id[id].file_path.downcase
      file_hints.any? { |h| path.include?(h) }
    end

    # ---- Final blend + penalty (SPEC §6.6) ----------------------------------

    def blend(id, confidence, norm_rrf)
      final = Config::CONFIDENCE_WEIGHT * confidence +
              (1 - Config::CONFIDENCE_WEIGHT) * norm_rrf
      path = @chunks_by_id[id].file_path.downcase
      final *= Config::PATH_PENALTY if Config::PATH_PENALTY_MARKERS.any? { |m| path.include?(m) }
      final
    end

    # ---- Diversity cap (SPEC §6.6) ------------------------------------------

    def apply_diversity(ranked, top_k)
      per_file = Hash.new(0)
      kept = []
      ranked.each do |x|
        fp = x[:chunk].file_path
        next if per_file[fp] >= Config::MAX_CHUNKS_PER_FILE

        per_file[fp] += 1
        kept << x
        break if kept.length >= top_k
      end
      kept
    end

    # ---- Graph expansion (SPEC §6.7) ----------------------------------------

    def expand_graph(results, qv)
      return [] if results.empty?

      result_files = results.map { |r| r[:file_path] }
      seen_spans = results.map { |r| [r[:file_path], r[:start_line], r[:end_line]] }.to_set

      top_files = result_files.first(3)
      neighbor_files = []
      top_files.each do |f|
        @graph_store.neighbors(f).each do |nb|
          next if result_files.include?(nb)
          next if neighbor_files.include?(nb)

          neighbor_files << nb
        end
      end
      neighbor_files = neighbor_files.first(Config::GRAPH_MAX_BONUS_FILES)

      bonus = []
      neighbor_files.each do |nf|
        chunks = @chunks_by_file[nf]
        scored = chunks.map { |c| { chunk: c, cosine: @vector_store.cosine_to(c.chunk_id, qv) } }
        # rank by cosine desc, tie chunk_id asc
        scored = NumericFormat.sort_by_score_desc(
          scored, score: ->(x) { x[:cosine] }, id: ->(x) { x[:chunk].chunk_id }
        ).first(2)
        scored.each do |s|
          span = [s[:chunk].file_path, s[:chunk].start_line, s[:chunk].end_line]
          next if seen_spans.include?(span)

          seen_spans << span
          score = [0.0, s[:cosine]].max * Config::GRAPH_BONUS_CHUNK_SCALE
          bonus << { chunk: s[:chunk], score: score }
        end
      end
      bonus
    end

    def extract_file_hints(query)
      query.to_s.split(/\s+/).select { |w| w.include?(".") }.map(&:downcase)
    end

    def to_result(chunk, score, rank)
      {
        rank: rank,
        chunk_id: chunk.chunk_id,
        file_path: chunk.file_path,
        start_line: chunk.start_line,
        end_line: chunk.end_line,
        chunk_type: chunk.chunk_type,
        language: chunk.language,
        token_count: chunk.token_count,
        content: chunk.content,
        score: score
      }
    end

    def ascii_downcase(str)
      self.class.ascii_downcase(str)
    end
  end
end
