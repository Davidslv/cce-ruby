# WHY: Python source expresses reusable units as `def` and `class`; retrieval
#      wants those as chunks, and its `import` / `from … import` statements as the
#      edges that connect files. This pack teaches the engine exactly that about
#      Python and nothing more (SPEC-V2 §2).
# WHAT: The Python LanguagePack — node types, import extraction, self-test sample.
# RESPONSIBILITIES:
#   - Map `function_definition`/`class_definition` to function/class chunks.
#   - Extract first-segment module names from `import` and `from … import`.
#   - Carry the Python conformance sample + its expected result.

require_relative "base"

module CCE
  module Packs
    class Python < Base
      def name = "python"
      def extensions = [".py"]
      def grammar_name = "python"
      def function_types = ["function_definition"]
      def class_types = ["class_definition"]

      def import_node_types
        %w[import_statement import_from_statement dotted_name aliased_import relative_import identifier]
      end

      def extract_imports(root_node, source)
        bytes = source.b
        names = []
        walk(root_node) do |node|
          collect(node, bytes, names)
        rescue StandardError
          next
        end
        names.uniq
      end

      def sample
        <<~PY
          import os

          def read_config(path):
              return os.path.join(path, "config.yml")

          class Loader:
              def load(self):
                  return read_config(".")
        PY
      end

      def expected
        Expected.new(
          min_functions: 2, min_classes: 1,
          kinds: %w[function_definition class_definition],
          imports: ["os"]
        )
      end

      private

      def collect(node, bytes, names)
        case node.type.to_s
        when "import_statement"
          each_child(node) do |c|
            ct = c.type.to_s
            dn = ct == "aliased_import" ? first_child_of_type(c, "dotted_name") : (c if ct == "dotted_name")
            names << first_identifier(dn, bytes) if dn
          end
        when "import_from_statement"
          mod = first_child_of_type(node, "dotted_name", "relative_import")
          n = first_identifier(mod, bytes) if mod
          names << n if n && !n.empty?
        end
      end

      def first_identifier(node, bytes)
        return nil unless node
        return node_text(node, bytes) if node.type.to_s == "identifier"

        c = first_child_of_type(node, "identifier")
        c ? node_text(c, bytes) : nil
      end
    end
  end
end
