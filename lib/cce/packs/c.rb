# WHY: C expresses units as `function_definition`s and aggregate types
#      (`struct`/`union`/`enum` specifiers), and connects files with the
#      preprocessor `#include`. This pack teaches the engine that shape so C code
#      chunks and graphs like any other language (SPEC-V2 §2).
# WHAT: The C LanguagePack — node types, `#include` imports, self-test sample.
# RESPONSIBILITIES:
#   - Map `function_definition` to function chunks and struct/union/enum
#     specifiers to class chunks.
#   - Extract the `#include` target's basename without extension
#     (`<stdlib.h>` → "stdlib", `"store.h"` → "store").
#   - Carry the C conformance sample + its expected result.

require_relative "base"

module CCE
  module Packs
    class C < Base
      def name = "c"
      def extensions = [".c", ".h"]
      def grammar_name = "c"
      def function_types = ["function_definition"]
      def class_types = %w[struct_specifier union_specifier enum_specifier]
      def import_node_types = %w[preproc_include system_lib_string string_literal string_content]

      def extract_imports(root_node, source)
        bytes = source.b
        names = []
        walk(root_node) do |node|
          next unless node.type.to_s == "preproc_include"

          name = include_target(node, bytes)
          names << name if name && !name.empty?
        rescue StandardError
          next
        end
        names.uniq
      end

      def sample
        <<~C
          #include <stdlib.h>

          struct Node {
              int value;
          };

          int sum_node(struct Node *n) {
              return n->value;
          }
        C
      end

      def expected
        Expected.new(
          min_functions: 1, min_classes: 1,
          kinds: %w[function_definition struct_specifier],
          imports: ["stdlib"]
        )
      end

      private

      # `#include <stdlib.h>` → "stdlib"; `#include "store.h"` → "store".
      def include_target(node, bytes)
        sys = first_child_of_type(node, "system_lib_string")
        if sys
          raw = node_text(sys, bytes).gsub(/\A<|>\z/, "")
          return basename_no_ext(raw)
        end

        str = first_child_of_type(node, "string_literal", "string")
        return nil unless str

        content = first_child_of_type(str, "string_content")
        raw = content ? node_text(content, bytes) : node_text(str, bytes).gsub(/\A"|"\z/, "")
        basename_no_ext(raw)
      end

      def basename_no_ext(path)
        base = File.basename(path.to_s.strip)
        File.basename(base, File.extname(base))
      end
    end
  end
end
