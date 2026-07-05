# WHY: Searching whole files is wasteful; the engine retrieves *symbols*. The
#      chunker turns source into function/class chunks (with a whole-file
#      fallback) plus the import edges that power graph expansion. Its output
#      determines chunk IDs and therefore the conformance gate (SPEC §4).
# WHAT: tree-sitter driven chunk extraction, import extraction, deterministic
#       chunk IDs, and token counting.
# RESPONSIBILITIES:
#   - Resolve a file's language by extension (SPEC §4.2).
#   - Walk the parse tree depth-first emitting a chunk for every function/class
#     node (nested ones too); fall back to a single "module" chunk otherwise.
#   - Extract deduplicated first-segment import names (SPEC §4.2).
#   - Compute chunk_id (SPEC §4.3) and token_count (SPEC §4.4).
#   - Deliberately NOT own persistence, embedding, or ranking.

require "digest"
require "tree_sitter"
require_relative "config"
require_relative "grammars"

module CCE
  # An immutable extracted unit of code.
  Chunk = Struct.new(
    :chunk_id, :file_path, :start_line, :end_line,
    :chunk_type, :language, :content, :token_count,
    keyword_init: true
  )

  module Chunker
    module_function

    # Node types that produce chunks, per language (SPEC §4.2).
    PY_FUNCTION = %w[function_definition].freeze
    PY_CLASS    = %w[class_definition].freeze
    JS_FUNCTION = %w[function_declaration method_definition arrow_function function_expression].freeze
    JS_CLASS    = %w[class_declaration].freeze

    # Resolve language from a file path's extension (nil if unknown).
    def language_for(path)
      Config::LANGUAGE_BY_EXT[File.extname(path).downcase]
    end

    # Produce all chunks for one file's content (SPEC §4.2).
    # @param content [String] raw file contents
    # @param file_path [String] path relative to indexed root, using "/"
    # @return [Array<Chunk>]
    def chunk_file(content, file_path)
      lang = language_for(file_path)
      chunks = lang ? parse_chunks(content, file_path, lang) : []
      return chunks unless chunks.empty?

      [fallback_chunk(content, file_path, lang)]
    end

    # Parse with tree-sitter and emit function/class chunks. Any failure yields
    # an empty list so the caller falls back to a whole-file chunk.
    def parse_chunks(content, file_path, lang)
      grammar = Grammars.language(lang)
      return [] unless grammar

      bytes = content.b
      tree = parse(grammar, bytes)
      return [] unless tree

      out = []
      fn_types, cls_types = node_type_sets(lang)
      walk(tree.root_node) do |node|
        type = node.type.to_s
        if fn_types.include?(type)
          out << build_chunk(node, bytes, file_path, lang, "function")
        elsif cls_types.include?(type)
          out << build_chunk(node, bytes, file_path, lang, "class")
        end
      end
      out
    rescue StandardError
      []
    end

    def node_type_sets(lang)
      case lang
      when "python"     then [PY_FUNCTION, PY_CLASS]
      when "javascript" then [JS_FUNCTION, JS_CLASS]
      else [[], []]
      end
    end

    def parse(grammar, bytes)
      parser = TreeSitter::Parser.new
      parser.language = grammar
      parser.parse_string(nil, bytes)
    rescue StandardError
      nil
    end

    # Depth-first, children in order; yields every node once (SPEC §4.2 walk).
    def walk(node, &block)
      block.call(node)
      i = 0
      count = node.child_count
      while i < count
        walk(node.child(i), &block)
        i += 1
      end
    end

    def build_chunk(node, bytes, file_path, lang, chunk_type)
      start_byte = node.start_byte
      end_byte = node.end_byte
      raw = bytes.byteslice(start_byte, end_byte - start_byte)
      content = raw.dup.force_encoding(Encoding::UTF_8)
      start_line = node.start_point.row + 1
      end_line = node.end_point.row + 1
      make_chunk(content, file_path, start_line, end_line, chunk_type, lang)
    end

    def fallback_chunk(content, file_path, lang)
      make_chunk(
        content,
        file_path,
        1,
        content.count("\n") + 1, # consistent with tree-sitter line numbering
        "module",
        lang || "plaintext"
      )
    end

    def make_chunk(content, file_path, start_line, end_line, chunk_type, language)
      Chunk.new(
        chunk_id: chunk_id(file_path, start_line, end_line, content),
        file_path: file_path,
        start_line: start_line,
        end_line: end_line,
        chunk_type: chunk_type,
        language: language,
        content: content,
        token_count: token_count(content)
      )
    end

    # Deterministic, cross-language identical chunk id (SPEC §4.3).
    def chunk_id(file_path, start_line, end_line, content)
      prefix = content.b[0, 100] || "".b
      id_input = +"#{file_path}:#{start_line}:#{end_line}:".b
      id_input << prefix
      Digest::SHA256.hexdigest(id_input)[0, 16]
    end

    # token_count = max(1, floor(bytelen / CHARS_PER_TOKEN)) (SPEC §4.4).
    def token_count(content)
      [1, content.bytesize / Config::CHARS_PER_TOKEN].max
    end

    # ---- Import extraction (SPEC §4.2) ---------------------------------------

    # @return [Array<String>] deduplicated first-segment module names (order kept)
    def extract_imports(content, lang)
      grammar = Grammars.language(lang)
      return [] unless grammar

      bytes = content.b
      tree = parse(grammar, bytes)
      return [] unless tree

      names = []
      walk(tree.root_node) do |node|
        case lang
        when "python"     then collect_python_import(node, bytes, names)
        when "javascript" then collect_js_import(node, bytes, names)
        end
      rescue StandardError
        next
      end
      names.uniq
    rescue StandardError
      []
    end

    def collect_python_import(node, bytes, names)
      case node.type.to_s
      when "import_statement"
        # `import a.b, c` -> dotted_name / aliased_import children
        each_child(node) do |c|
          ct = c.type.to_s
          dn = ct == "aliased_import" ? first_child_of_type(c, "dotted_name") : (c if ct == "dotted_name")
          names << first_identifier(dn, bytes) if dn
        end
      when "import_from_statement"
        # module is the first dotted_name / relative_import child (before `import`)
        mod = first_module_child(node)
        n = first_identifier(mod, bytes) if mod
        names << n if n && !n.empty?
      end
    end

    def collect_js_import(node, bytes, names)
      return unless node.type.to_s == "import_statement"

      str = first_child_of_type(node, "string")
      return unless str

      raw = node_text(str, bytes)
      spec = raw.gsub(/\A['"`]|['"`]\z/, "")
      seg = first_path_segment(spec)
      names << seg unless seg.nil? || seg.empty?
    end

    def first_path_segment(spec)
      s = spec.dup
      s = s.sub(%r{\A(?:\.\./|\./)+}, "") # drop leading ./ and ../
      s.split("/").reject(&:empty?).first
    end

    def each_child(node)
      i = 0
      count = node.child_count
      while i < count
        yield node.child(i)
        i += 1
      end
    end

    def first_child_of_type(node, type)
      i = 0
      count = node.child_count
      while i < count
        c = node.child(i)
        return c if c.type.to_s == type

        i += 1
      end
      nil
    end

    def first_module_child(node)
      i = 0
      count = node.child_count
      while i < count
        c = node.child(i)
        return c if %w[dotted_name relative_import].include?(c.type.to_s)

        i += 1
      end
      nil
    end

    def first_identifier(node, bytes)
      return nil unless node

      if node.type.to_s == "identifier"
        return node_text(node, bytes)
      end

      # dotted_name/relative_import: first identifier descendant text
      i = 0
      count = node.child_count
      while i < count
        c = node.child(i)
        return node_text(c, bytes) if c.type.to_s == "identifier"

        i += 1
      end
      nil
    end

    def node_text(node, bytes)
      bytes.byteslice(node.start_byte, node.end_byte - node.start_byte)
           .dup.force_encoding(Encoding::UTF_8)
    end
  end
end
