# WHY: Relevant code often lives one import away from a top hit. A small import
#      graph lets retrieval expand into neighbouring files (SPEC §6.7).
# WHAT: A file-level import graph with undirected neighbour lookup.
# RESPONSIBILITIES:
#   - Resolve each file's imported module names to corpus files (by path stem or
#     "<module>.py"/"<module>.js" suffix) and record directed edges.
#   - Answer neighbour queries treating edges as undirected.
#   - Deliberately NOT own ranking or which chunks to pull (the retriever does).

module CCE
  class GraphStore
    # @param file_imports [Hash{String=>Array<String>}] file_path => module names
    # @param files [Array<String>] all corpus file paths
    def initialize(file_imports, files)
      @files = files
      @adj = Hash.new { |h, k| h[k] = [] }
      by_stem = build_stem_index(files)

      file_imports.each do |from, modules|
        modules.each do |mod|
          target = resolve(mod, by_stem, files)
          next if target.nil? || target == from

          add_edge(from, target)
        end
      end
    end

    # Undirected neighbours of a file, in stable first-seen order.
    def neighbors(file_path)
      @adj[file_path].uniq
    end

    private

    def build_stem_index(files)
      index = Hash.new { |h, k| h[k] = [] }
      files.each do |f|
        stem = File.basename(f, File.extname(f))
        index[stem] << f
      end
      index
    end

    # Resolve a module name to a corpus file (SPEC §6.7).
    def resolve(mod, by_stem, files)
      # 1) path stem (filename without extension) equals the module
      if by_stem.key?(mod) && !by_stem[mod].empty?
        return by_stem[mod].min # deterministic pick if multiple
      end

      # 2) a path ending in "<module>.py" or "<module>.js"
      candidates = files.select do |f|
        f.end_with?("#{mod}.py") || f.end_with?("#{mod}.js")
      end
      candidates.min
    end

    def add_edge(a, b)
      @adj[a] << b
      @adj[b] << a
    end
  end
end
