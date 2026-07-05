# WHY: Searching whole files is wasteful; the engine retrieves *symbols*. The
#      chunker turns source into function/class chunks (with a whole-file
#      fallback) plus the import edges that power graph expansion. Its output
#      determines chunk IDs and therefore the conformance gate (SPEC §4). It is
#      deliberately language-blind: every language-specific decision is delegated
#      to a LanguagePack resolved through the registry (SPEC-V2 §1), so this file
#      names no language and no extension.
# WHAT: registry-driven chunk extraction, import extraction, deterministic chunk
#       IDs, node-`kind` capture, and token counting.
# RESPONSIBILITIES:
#   - Resolve a file to its pack via the registry (nil => module fallback).
#   - Walk the parse tree depth-first emitting a chunk for every function/class
#     node the pack declares (nested ones too); otherwise one "module" chunk.
#   - Delegate import extraction to the pack.
#   - Compute chunk_id (SPEC §4.3, unchanged — `kind` is not part of it) and
#     token_count (SPEC §4.4), and record each chunk's exact node `kind`.
#   - Deliberately NOT own persistence, embedding, ranking, or any language rule.

require "digest"
require "tree_sitter"
require_relative "config"

module CCE
  # An immutable extracted unit of code. `chunk_type` is the coarse bucket
  # (function/class/module); `kind` is the exact tree-sitter node type.
  Chunk = Struct.new(
    :chunk_id, :file_path, :start_line, :end_line,
    :chunk_type, :kind, :language, :content, :token_count,
    keyword_init: true
  )

  module Chunker
    MODULE_KIND = "module"

    module_function

    def registry
      CCE.registry
    end

    # Resolve the language name for a file, or nil if no pack claims it.
    def language_for(path, registry: registry())
      registry.pack_for(path)&.name
    end

    # Produce all chunks for one file's content (SPEC §4.2).
    # @param content [String] raw file contents
    # @param file_path [String] path relative to indexed root, using "/"
    # @return [Array<Chunk>]
    def chunk_file(content, file_path, registry: registry())
      pack = registry.pack_for(file_path)
      chunks = pack ? parse_chunks(content, file_path, pack) : []
      return chunks unless chunks.empty?

      [fallback_chunk(content, file_path, pack)]
    end

    # Parse with tree-sitter and emit function/class chunks for a pack's node
    # types. Any failure yields an empty list so the caller falls back.
    def parse_chunks(content, file_path, pack)
      grammar = pack.grammar
      return [] unless grammar

      bytes = content.b
      tree = parse(grammar, bytes)
      return [] unless tree

      out = []
      fn_types = pack.function_types
      cls_types = pack.class_types
      walk(tree.root_node) do |node|
        # Match only *named* grammar nodes: some grammars spell a definition
        # node and its keyword token with the same type string, and only the
        # definition is a named node — matching both would double-count.
        next unless node.named?

        type = node.type.to_s
        if fn_types.include?(type)
          out << build_chunk(node, bytes, file_path, pack.name, "function", type)
        elsif cls_types.include?(type)
          out << build_chunk(node, bytes, file_path, pack.name, "class", type)
        end
      end
      out
    rescue StandardError
      []
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

    def build_chunk(node, bytes, file_path, language, chunk_type, kind)
      start_byte = node.start_byte
      end_byte = node.end_byte
      raw = bytes.byteslice(start_byte, end_byte - start_byte)
      content = raw.dup.force_encoding(Encoding::UTF_8)
      start_line = node.start_point.row + 1
      end_line = node.end_point.row + 1
      make_chunk(content, file_path, start_line, end_line, chunk_type, kind, language)
    end

    # The language-neutral fallback: one chunk over the whole file. Its end_line
    # is the number of "\n" bytes + 1 (SPEC-V2 §4), so a file ending in a newline
    # still counts that trailing line — identical across languages.
    def fallback_chunk(content, file_path, pack)
      end_line = content.b.count("\n") + 1
      make_chunk(content, file_path, 1, end_line, "module", MODULE_KIND, pack ? pack.name : "plaintext")
    end

    def make_chunk(content, file_path, start_line, end_line, chunk_type, kind, language)
      Chunk.new(
        chunk_id: chunk_id(file_path, start_line, end_line, content),
        file_path: file_path,
        start_line: start_line,
        end_line: end_line,
        chunk_type: chunk_type,
        kind: kind,
        language: language,
        content: content,
        token_count: token_count(content)
      )
    end

    # Deterministic, cross-language identical chunk id (SPEC §4.3). `kind` is
    # intentionally NOT part of the id.
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

    # Deduplicated, ordered import names for a file, delegated to its pack.
    # @return [Array<String>]
    def extract_imports(content, file_path, registry: registry())
      pack = registry.pack_for(file_path)
      return [] unless pack

      grammar = pack.grammar
      return [] unless grammar

      tree = parse(grammar, content.b)
      return [] unless tree

      Array(pack.extract_imports(tree.root_node, content))
    rescue StandardError
      []
    end
  end
end
