# WHY: tree-sitter needs a compiled grammar shared library to parse a language.
#      Packs (lib/cce/packs/*) declare *which* grammar they need by name; this
#      module is the language-agnostic bridge that turns a grammar name into a
#      loaded `TreeSitter::Language`. It knows how to *find and load* a grammar,
#      but nothing about what any language means — that lives in the packs.
# WHAT: Lazy loader/cache of TreeSitter::Language objects keyed by grammar name.
# RESPONSIBILITIES:
#   - Ensure the required grammar dylib is present (prefetch on first use).
#   - Locate the dylib in the language-pack cache and load it via ruby_tree_sitter.
#   - Memoise loaded languages; return nil (never raise) when a grammar is absent.
#   - Deliberately NOT own chunking rules or any per-language node types.

require "tree_sitter"

module CCE
  module Grammars
    @languages = {}
    @prefetched = {}

    module_function

    # @param name [String] a tree-sitter grammar name, e.g. "ruby", "rust"
    # @return [TreeSitter::Language, nil] loaded grammar, or nil if unavailable
    def language(name)
      key = name.to_s
      return @languages[key] if @languages.key?(key)

      @languages[key] = load_language(key)
    rescue StandardError
      @languages[key] = nil
    end

    def load_language(name)
      path = dylib_path(name)
      return nil unless path

      TreeSitter::Language.load(name, path)
    rescue StandardError
      nil
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
      candidates.find { |p| File.exist?(p) }
    end

    def ensure_prefetched(name)
      require "tree_sitter_language_pack"
      return if @prefetched[name]

      begin
        TreeSitterLanguagePack.prefetch([name])
      rescue StandardError
        begin
          TreeSitterLanguagePack.download(name)
        rescue StandardError
          # Grammar genuinely unavailable; dylib_path returns nil, language nil.
        end
      end
      @prefetched[name] = true
    rescue LoadError
      # Pack gem absent: fall back to whatever dylibs already exist on disk.
      @prefetched[name] = true
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
