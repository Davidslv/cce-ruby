# WHY: Two implementations of this spec must produce identical results on a
#      fixed fixture. The conformance harness is the executable proof of that
#      equivalence and a hard acceptance gate (SPEC §8).
# WHAT: Indexes the fixture, runs the three canonical queries (graph disabled),
#       and emits the exact conformance.json structure — deterministically.
# RESPONSIBILITIES:
#   - Produce the sorted chunk manifest and per-query top-5 results.
#   - Format scores as fixed 6-decimal strings; sort chunks canonically.
#   - Emit stable, reproducible JSON.
#   - Deliberately NOT include graph expansion (runs with it disabled).

require "json"
require_relative "config"
require_relative "chunker"
require_relative "embedder"
require_relative "retriever"
require_relative "numeric_format"

module CCE
  module Conformance
    QUERIES = ["hash password", "process payment amount", "create session user"].freeze
    TOP_K = 5

    module_function

    # Build the conformance data structure for a fixture directory.
    # @return [Hash] the structure serialised by #to_json
    def run(fixture_dir, impl_language: "ruby")
      files = load_files(fixture_dir)
      embedder = HashEmbedder.new

      all_chunks = []
      file_imports = {}
      files.each do |rel, content|
        chunks = Chunker.chunk_file(content, rel)
        lang = Chunker.language_for(rel)
        file_imports[rel] = lang ? Chunker.extract_imports(content, lang) : []
        all_chunks.concat(chunks)
      end

      retriever = Retriever.new(all_chunks, embedder: embedder, file_imports: file_imports)

      {
        spec_version: Config::SPEC_VERSION,
        impl_language: impl_language,
        chunks: chunk_manifest(all_chunks),
        queries: QUERIES.map { |q| query_block(retriever, q) }
      }
    end

    # Deterministic JSON string (stable key order, 2-space indent).
    def to_json(fixture_dir, impl_language: "ruby")
      JSON.pretty_generate(stringify(run(fixture_dir, impl_language: impl_language)))
    end

    # Load the fixture files in a fixed order (README always present per spec).
    def load_files(dir)
      names = %w[auth.py payments.py README.md].select { |n| File.exist?(File.join(dir, n)) }
      # Fall back to any files present if the canonical names are absent.
      names = Dir.children(dir).select { |n| File.file?(File.join(dir, n)) }.sort if names.empty?
      names.map { |n| [n, File.read(File.join(dir, n))] }
    end

    def chunk_manifest(chunks)
      sorted = chunks.sort_by { |c| [c.file_path, c.start_line, c.chunk_id] }
      sorted.map do |c|
        {
          file_path: c.file_path,
          start_line: c.start_line,
          end_line: c.end_line,
          chunk_type: c.chunk_type,
          chunk_id: c.chunk_id,
          token_count: c.token_count
        }
      end
    end

    def query_block(retriever, query)
      results = retriever.search(query, top_k: TOP_K, graph_enabled: false)
      {
        query: query,
        top_k: TOP_K,
        graph_enabled: false,
        results: results.map do |r|
          {
            rank: r[:rank],
            chunk_id: r[:chunk_id],
            file_path: r[:file_path],
            score: NumericFormat.fmt6(r[:score])
          }
        end
      }
    end

    # Convert symbol keys to strings for JSON emission (stable order preserved).
    def stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
      when Array then obj.map { |v| stringify(v) }
      else obj
      end
    end
  end
end
