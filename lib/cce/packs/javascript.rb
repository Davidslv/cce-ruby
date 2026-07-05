# WHY: JavaScript scatters callables across function declarations, class methods,
#      and arrow/function expressions, and wires modules together with ES
#      `import … from "x"`. This pack captures that shape so the engine can chunk
#      and graph JavaScript without the core knowing the language exists (SPEC-V2 §2).
# WHAT: The JavaScript LanguagePack — node types, ES-module import extraction, sample.
# RESPONSIBILITIES:
#   - Map function declarations/methods/expressions to function chunks and
#     `class_declaration` to class chunks.
#   - Extract the first path segment of each `import … from "x"` specifier.
#   - Carry the JavaScript conformance sample + its expected result.

require_relative "base"
require_relative "es_modules"

module CCE
  module Packs
    class JavaScript < Base
      def name = "javascript"
      def extensions = [".js", ".jsx", ".mjs", ".cjs"]
      def grammar_name = "javascript"

      def function_types
        %w[function_declaration method_definition arrow_function function_expression]
      end

      def class_types = ["class_declaration"]
      def import_node_types = %w[import_statement string]

      def extract_imports(root_node, source)
        bytes = source.b
        names = []
        walk(root_node) do |node|
          next unless node.type.to_s == "import_statement"

          str = first_child_of_type(node, "string")
          next unless str

          spec = node_text(str, bytes).gsub(/\A['"`]|['"`]\z/, "")
          seg = EsModules.first_segment(spec)
          names << seg unless seg.nil? || seg.empty?
        rescue StandardError
          next
        end
        names.uniq
      end

      def sample
        <<~JS
          import fs from "fs";

          function readConfig(path) {
            return fs.readFileSync(path);
          }

          class Loader {
            load() {
              return readConfig(".");
            }
          }
        JS
      end

      def expected
        Expected.new(
          min_functions: 2, min_classes: 1,
          kinds: %w[function_declaration method_definition class_declaration],
          imports: ["fs"]
        )
      end
    end
  end
end
