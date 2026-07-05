# WHY: Ruby expresses units as `def` (methods and singleton methods) and groups
#      them under `class`/`module`; it wires files together with `require` and
#      `require_relative`. This pack teaches the engine that shape so Ruby code
#      chunks and graphs like any other language (SPEC-V2 §2).
# WHAT: The Ruby LanguagePack — node types, require-based imports, self-test sample.
# RESPONSIBILITIES:
#   - Map `method`/`singleton_method` to function chunks, `class`/`module` to class chunks.
#   - Extract the required name from `require`/`require_relative` calls, taking the
#     last path segment's stem (`require "a/b"` → "b").
#   - Carry the Ruby conformance sample + its expected result.

require_relative "base"

module CCE
  module Packs
    class Ruby < Base
      REQUIRE_METHODS = %w[require require_relative].freeze

      def name = "ruby"
      def extensions = [".rb"]
      def grammar_name = "ruby"
      def function_types = %w[method singleton_method]
      def class_types = %w[class module]
      def import_node_types = %w[call identifier argument_list string string_content]

      def extract_imports(root_node, source)
        bytes = source.b
        names = []
        walk(root_node) do |node|
          name = require_target(node, bytes)
          names << name if name
        rescue StandardError
          next
        end
        names.uniq
      end

      def sample
        <<~RUBY
          require "json"

          def parse_config(text)
            JSON.parse(text)
          end

          class Loader
            def load(path)
              parse_config(File.read(path))
            end
          end
        RUBY
      end

      def expected
        Expected.new(
          min_functions: 2, min_classes: 1,
          kinds: %w[method class],
          imports: ["json"]
        )
      end

      private

      # A `require`/`require_relative` call: identifier + argument_list(string).
      def require_target(node, bytes)
        return nil unless node.type.to_s == "call"

        ident = first_child_of_type(node, "identifier")
        return nil unless ident && REQUIRE_METHODS.include?(node_text(ident, bytes))

        args = first_child_of_type(node, "argument_list")
        return nil unless args

        str = first_child_of_type(args, "string")
        return nil unless str

        content = first_child_of_type(str, "string_content")
        raw = content ? node_text(content, bytes) : node_text(str, bytes).gsub(/\A['"]|['"]\z/, "")
        stem(raw)
      end

      # Last path segment without its extension: "a/b.rb" → "b".
      def stem(path)
        seg = path.to_s.split("/").reject(&:empty?).last
        return nil unless seg

        File.basename(seg, File.extname(seg))
      end
    end
  end
end
