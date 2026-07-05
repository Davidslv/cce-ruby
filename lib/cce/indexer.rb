# WHY: Indexing is the write path that turns a directory into a searchable
#      store. It ties together walking, chunking, import extraction, embedding,
#      and persistence in one place (SPEC §1, §7).
# WHAT: The index orchestration + a helper to build a Retriever from a store.
# RESPONSIBILITIES:
#   - Walk a directory, chunk each file, extract imports, embed every chunk.
#   - Persist everything via Store; return a summary for the CLI.
#   - Reconstruct a Retriever from a persisted store for search/conformance.
#   - Deliberately NOT own the ranking algorithm (Retriever) or CLI formatting.

require_relative "walker"
require_relative "chunker"
require_relative "embedder"
require_relative "ollama_embedder"
require_relative "store"
require_relative "retriever"

module CCE
  module Indexer
    module_function

    # Build an embedder by name.
    def build_embedder(name)
      case name.to_s
      when "ollama" then OllamaEmbedder.new
      else HashEmbedder.new
      end
    end

    # Index `root` into `store_path`.
    # @return [Hash] summary { files_indexed:, files_skipped:, total_chunks:, elapsed: }
    def index(root, store_path:, embedder: "hash")
      started = monotonic
      emb = embedder.is_a?(String) ? build_embedder(embedder) : embedder
      collected = Walker.collect(root)

      records = []
      file_imports = {}
      file_tokens = {}
      collected[:files].each do |f|
        chunks = Chunker.chunk_file(f[:content], f[:rel])
        lang = Chunker.language_for(f[:rel])
        file_imports[f[:rel]] = lang ? Chunker.extract_imports(f[:content], lang) : []
        # Whole-file token count for the counterfactual baseline (DASHBOARD-SPEC §3).
        file_tokens[f[:rel]] = Chunker.token_count(f[:content])
        vectors = emb.embed_batch(chunks.map(&:content))
        chunks.each_with_index do |c, i|
          records << { chunk: c, vector: vectors[i] }
        end
      end

      Store.create(store_path) do |s|
        s.write(records: records, file_imports: file_imports,
                file_tokens: file_tokens, embedder: emb.name)
      end

      {
        files_indexed: collected[:files].length,
        files_skipped: collected[:skipped],
        total_chunks: records.length,
        elapsed: monotonic - started,
        store_path: store_path
      }
    end

    # Load a store and build a ready-to-query Retriever.
    def retriever_from_store(store_path, embedder: nil)
      store = Store.open(store_path)
      begin
        chunks = store.chunks
        vectors = store.vectors
        emb = embedder || build_embedder(store.embedder_name)
        Retriever.new(chunks, embedder: emb, vectors: vectors, file_imports: store.file_imports)
      ensure
        store.close
      end
    end

    # Load the persisted whole-file token counts (DASHBOARD-SPEC §3) for a store.
    def file_token_counts(store_path)
      store = Store.open(store_path)
      begin
        store.file_token_counts
      ensure
        store.close
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
