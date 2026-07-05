# WHY: TypeScript shares JavaScript's callable shapes but adds `interface` and
#      `enum` declarations to the type surface worth chunking; it imports with the
#      same ES-module `import … from "x"` grammar. This pack teaches the engine
#      that superset without the core knowing either language (SPEC-V2 §2).
# WHAT: The TypeScript LanguagePack — node types, ES-module imports, self-test sample.
# RESPONSIBILITIES:
#   - Map function declarations/methods/expressions to function chunks and
#     class/interface/enum declarations to class chunks.
#   - Extract the first path segment of each `import … from "x"` specifier.
#   - Carry the TypeScript conformance sample + its expected result.

require_relative "base"
require_relative "es_modules"

module CCE
  module Packs
    class TypeScript < Base
      def name = "typescript"
      def extensions = [".ts", ".tsx"]
      def grammar_name = "typescript"

      def function_types
        %w[function_declaration method_definition arrow_function function_expression]
      end

      def class_types = %w[class_declaration interface_declaration enum_declaration]
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
        <<~TS
          import { readFile } from "fs";

          export function loadConfig(path: string): string {
            return readFile(path);
          }

          export interface Config {
            name: string;
          }

          export class Loader {
            load(): Config {
              return { name: loadConfig(".") };
            }
          }
        TS
      end

      def expected
        Expected.new(
          min_functions: 2, min_classes: 2,
          kinds: %w[function_declaration method_definition interface_declaration class_declaration],
          imports: ["fs"]
        )
      end
    end
  end
end
