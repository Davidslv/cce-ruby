# WHY: Retrieval needs each chunk (and each query) represented as a comparable
#      vector. The default must be deterministic and model-free so results are
#      reproducible across machines and languages (SPEC §5).
# WHAT: The signed hashing embedder (default), the cosine similarity function,
#       and a shared Embedder namespace the optional Ollama backend also uses.
# RESPONSIBILITIES:
#   - HashEmbedder: turn text into a 256-dim L2-normalised f64 vector via
#     tokenizer + FNV-1a bucketing with a sign bit (SPEC §5.1).
#   - Embedder.cosine: dot product of two normalised vectors (SPEC §5.2).
#   - Deliberately NOT own persistence or ranking.

require_relative "config"
require_relative "tokenizer"
require_relative "hashing"

module CCE
  module Embedder
    module_function

    # Cosine similarity of two vectors. Since embeddings are L2-normalised this
    # is a plain dot product summed in index order (SPEC §5.2).
    def cosine(a, b)
      sum = 0.0
      i = 0
      n = a.length
      while i < n
        sum += a[i] * b[i]
        i += 1
      end
      sum
    end
  end

  # Deterministic hashing embedder (SPEC §5.1) — the default backend.
  class HashEmbedder
    DIM = Config::EMBED_DIM

    def name
      "hash"
    end

    # @param text [String]
    # @return [Array<Float>] 256-dim L2-normalised vector (all-zero if no tokens)
    def embed(text)
      v = Array.new(DIM, 0.0)
      Tokenizer.tokenize(text).each do |tok|
        h = Hashing.fnv1a64(tok)
        bucket = h % DIM
        sign = ((h >> 63) & 1) == 1 ? -1.0 : 1.0
        v[bucket] += sign
      end
      norm = 0.0
      v.each { |x| norm += x * x }
      norm = Math.sqrt(norm)
      if norm > 0
        i = 0
        while i < DIM
          v[i] /= norm
          i += 1
        end
      end
      v
    end

    # Convenience batch API shared with the Ollama backend interface.
    def embed_batch(texts)
      texts.map { |t| embed(t) }
    end
  end
end
