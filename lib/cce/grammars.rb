# WHY: tree-sitter needs compiled grammar shared libraries to parse a language.
#      We depend on the `tree_sitter_language_pack` gem to download prebuilt
#      Python/JavaScript parsers, then hand their dylib paths to the
#      `ruby_tree_sitter` bindings which do the actual parsing. This file is the
#      bridge between those two gems.
# WHAT: Lazy loader/cache of TreeSitter::Language objects keyed by language name.
# RESPONSIBILITIES:
#   - Ensure the required grammar dylib is present (prefetch on first use).
#   - Locate the dylib in the language-pack cache and load it via ruby_tree_sitter.
#   - Memoise loaded languages; expose nil for unsupported languages.
#   - Deliberately NOT own chunking rules (that is the chunker's job).

require "tree_sitter"

module CCE
  module Grammars
    SUPPORTED = %w[python javascript].freeze

    @languages = {}
    @loaded_pack = false

    module_function

    # @param name [String] "python" or "javascript"
    # @return [TreeSitter::Language, nil] loaded grammar, or nil if unsupported
    def language(name)
      return nil unless SUPPORTED.include?(name)

      @languages[name] ||= load_language(name)
    end

    def load_language(name)
      path = dylib_path(name)
      TreeSitter::Language.load(name, path)
    end

    # Resolve the dylib path from the language-pack cache, prefetching if needed.
    def dylib_path(name)
      ensure_prefetched(name)
      candidates = pack_lib_dirs.flat_map do |dir|
        [
          File.join(dir, "libtree_sitter_#{name}.dylib"),
          File.join(dir, "libtree_sitter_#{name}.so"),
          File.join(dir, "tree-sitter-#{name}.dylib"),
          File.join(dir, "#{name}.dylib")
        ]
      end
      found = candidates.find { |p| File.exist?(p) }
      raise "grammar dylib for #{name} not found (looked in #{pack_lib_dirs.inspect})" unless found

      found
    end

    def ensure_prefetched(name)
      require "tree_sitter_language_pack"
      unless @loaded_pack
        # Downloads any missing grammar dylibs into the pack cache. Cheap no-op
        # once cached; the default test suite relies on the cache already warm.
        begin
          TreeSitterLanguagePack.prefetch(SUPPORTED)
        rescue StandardError
          TreeSitterLanguagePack.download(name)
        end
        @loaded_pack = true
      end
    rescue LoadError
      # Pack gem absent: fall back to whatever dylibs already exist on disk.
      @loaded_pack = true
    end

    def pack_lib_dirs
      dirs = []
      begin
        require "tree_sitter_language_pack"
        base = TreeSitterLanguagePack.cache_dir
        if base
          dirs << base
          dirs << File.join(base, "libs")
        end
      rescue StandardError
        # ignore
      end
      dirs << ENV["TREE_SITTER_PARSERS"] if ENV["TREE_SITTER_PARSERS"]
      dirs.compact.uniq
    end
  end
end
