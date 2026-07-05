# WHY: A LanguagePack is the single unit that carries *all* knowledge about one
#      language, so the core engine can stay language-blind (SPEC-V2 §1). This
#      base collects the machinery every pack shares — grammar loading, the
#      expected-result value object, and low-level tree-walk helpers — so each
#      concrete pack file holds only its own language's node types and rules.
# WHAT: The abstract base every pack subclasses, plus the `Expected` value object
#       that a pack's behavioural self-test (SPEC-V2 §5, Layer 3) checks against.
# RESPONSIBILITIES:
#   - Declare the pack interface (name/extensions/grammar_name/function_types/
#     class_types/import_node_types/extract_imports/sample/expected).
#   - Load and memoise the pack's tree-sitter grammar via Grammars.
#   - Provide generic, language-neutral node helpers for import extraction.
#   - Deliberately hold NO node-type strings or language names of its own.

require_relative "../grammars"

module CCE
  module Packs
    # What a pack's `sample` must produce, checked by the Layer-3 self-test.
    #   min_functions / min_classes : minimum chunk counts of each coarse type
    #   kinds                       : node-type `kind`s that must all be present
    #   imports                     : the exact, ordered extract_imports result
    Expected = Struct.new(:min_functions, :min_classes, :kinds, :imports, keyword_init: true)

    # Abstract base. Subclasses declare node types and import extraction; the
    # engine only ever talks to packs through this interface.
    class Base
      # ---- Interface a concrete pack MUST provide -----------------------------

      # @return [String] unique lowercase id, e.g. "ruby"
      def name = raise(NotImplementedError, "pack must define #name")

      # @return [Array<String>] claimed extensions, leading dot, lowercase
      def extensions = raise(NotImplementedError, "pack must define #extensions")

      # @return [String] the tree-sitter grammar name to load
      def grammar_name = raise(NotImplementedError, "pack must define #grammar_name")

      # @return [Array<String>] AST node types that become `function` chunks
      def function_types = raise(NotImplementedError, "pack must define #function_types")

      # @return [Array<String>] AST node types that become `class` chunks
      def class_types = raise(NotImplementedError, "pack must define #class_types")

      # AST node types this pack inspects while extracting imports. Declared so
      # the grammar-binding lint (Layer 2) can verify they exist in the grammar.
      # @return [Array<String>]
      def import_node_types = []

      # Ordered, de-duplicated module/include names for a parse tree.
      # @param root_node [TreeSitter::Node] the parsed root
      # @param source [String] the raw (byte) source
      # @return [Array<String>]
      def extract_imports(_root_node, _source) = raise(NotImplementedError, "pack must define #extract_imports")

      # @return [String] a small self-test source snippet (SPEC-V2 §6)
      def sample = raise(NotImplementedError, "pack must define #sample")

      # @return [Expected] what `sample` must produce
      def expected = raise(NotImplementedError, "pack must define #expected")

      # ---- Shared machinery ---------------------------------------------------

      # @return [TreeSitter::Language, nil] the loaded grammar (memoised)
      def grammar
        return @grammar if defined?(@grammar)

        @grammar = Grammars.language(grammar_name)
      end

      def to_s = "#<pack:#{name}>"

      protected

      # Depth-first walk yielding every node once (children in order).
      def walk(node, &block)
        block.call(node)
        i = 0
        count = node.child_count
        while i < count
          walk(node.child(i), &block)
          i += 1
        end
      end

      # Raw UTF-8 text of a node.
      def node_text(node, bytes)
        bytes.byteslice(node.start_byte, node.end_byte - node.start_byte)
             .dup.force_encoding(Encoding::UTF_8)
      end

      def each_child(node)
        i = 0
        count = node.child_count
        while i < count
          yield node.child(i)
          i += 1
        end
      end

      def first_child_of_type(node, *types)
        i = 0
        count = node.child_count
        while i < count
          c = node.child(i)
          return c if types.include?(c.type.to_s)

          i += 1
        end
        nil
      end
    end
  end
end
