# WHY: The hashing embedder is deterministic but purely lexical. For real
#      semantic search users may prefer a model. Ollama provides local
#      embeddings behind the same interface (SPEC §11), keeping the two backends
#      interchangeable without touching the pipeline.
# WHAT: An HTTP client for a local Ollama server implementing #embed/#embed_batch.
# RESPONSIBILITIES:
#   - Call POST /api/embed with {model, input:[...]} and read .embeddings.
#   - Truncate long inputs (~2000 chars) and skip empty inputs.
#   - Fail with a clear, actionable error when the server is unreachable.
#   - Deliberately NOT participate in conformance (model-dependent vectors).

require "net/http"
require "json"
require "uri"

module CCE
  class OllamaEmbedder
    DEFAULT_HOST = "http://localhost:11434"
    MODEL = "nomic-embed-text"
    MAX_CHARS = 2000

    class Unreachable < StandardError; end

    def initialize(host: ENV["OLLAMA_HOST"] || DEFAULT_HOST, model: MODEL)
      @host = host
      @model = model
    end

    def name
      "ollama"
    end

    def embed(text)
      embed_batch([text]).first
    end

    # @param texts [Array<String>]
    # @return [Array<Array<Float>>] one embedding per input (zero vector for empty)
    def embed_batch(texts)
      prepared = texts.map { |t| truncate(t.to_s) }
      non_empty = prepared.reject(&:empty?)
      embeddings = non_empty.empty? ? [] : request(non_empty)

      # Re-align embeddings with original inputs, using a zero vector for empties.
      dim = embeddings.first&.length || 0
      idx = 0
      prepared.map do |t|
        if t.empty?
          Array.new(dim, 0.0)
        else
          e = embeddings[idx]
          idx += 1
          e
        end
      end
    end

    private

    def truncate(text)
      text.length > MAX_CHARS ? text[0, MAX_CHARS] : text
    end

    def request(inputs)
      uri = URI.join(@host + "/", "api/embed")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 5
      http.read_timeout = 60
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(model: @model, input: inputs)
      res = http.request(req)
      raise Unreachable, "Ollama returned HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body)
      data.fetch("embeddings")
    rescue SystemCallError, Timeout::Error, SocketError => e
      raise Unreachable,
            "Cannot reach Ollama at #{@host} (#{e.message}). " \
            "Start it, or use the default hash embedder (--embedder hash)."
    end
  end
end
