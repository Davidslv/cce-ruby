# WHY: Rust spreads definitions across `fn` items and the family of type items
#      (`struct`/`enum`/`trait`/`impl`/`union`), and connects modules with `use`
#      paths. This pack teaches the engine that shape — including that an `impl`
#      block and the `fn`s inside it both chunk (SPEC-V2 §1, §2).
# WHAT: The Rust LanguagePack — node types, `use`-path imports, self-test sample.
# RESPONSIBILITIES:
#   - Map `function_item` to function chunks and the type-item family to class chunks.
#   - Extract the first segment of every `use` path ("std::collections::…" → "std").
#   - Carry the Rust conformance sample + its expected result.

require_relative "base"

module CCE
  module Packs
    class Rust < Base
      # Leftmost path leaves worth treating as an import root.
      PATH_ROOTS = %w[identifier crate self super metavariable].freeze

      def name = "rust"
      def extensions = [".rs"]
      def grammar_name = "rust"
      def function_types = ["function_item"]
      def class_types = %w[struct_item enum_item trait_item impl_item union_item]
      def import_node_types = %w[use_declaration scoped_identifier identifier]

      def extract_imports(root_node, source)
        bytes = source.b
        names = []
        walk(root_node) do |node|
          next unless node.type.to_s == "use_declaration"

          seg = first_use_segment(node, bytes)
          names << seg if seg && !seg.empty?
        rescue StandardError
          next
        end
        names.uniq
      end

      def sample
        <<~RUST
          use std::collections::HashMap;

          pub fn build_index() -> HashMap<String, u32> {
              HashMap::new()
          }

          pub struct Store {
              data: HashMap<String, u32>,
          }

          impl Store {
              pub fn get(&self, key: &str) -> u32 {
                  0
              }
          }
        RUST
      end

      def expected
        Expected.new(
          min_functions: 2, min_classes: 2,
          kinds: %w[function_item struct_item impl_item],
          imports: ["std"]
        )
      end

      private

      # The first path segment of `use a::b::c;` — descend the leftmost child of
      # nested `scoped_identifier`s until we reach a path root leaf.
      def first_use_segment(use_node, bytes)
        path = first_child_of_type(
          use_node, "scoped_identifier", "identifier", "crate",
          "scoped_use_list", "use_as_clause", "use_wildcard", "use_list"
        )
        return nil unless path

        leftmost_root(path, bytes)
      end

      def leftmost_root(node, bytes)
        cur = node
        loop do
          type = cur.type.to_s
          return node_text(cur, bytes) if PATH_ROOTS.include?(type)

          child = cur.child_count.positive? ? cur.child(0) : nil
          return nil unless child

          cur = child
        end
      end
    end
  end
end
