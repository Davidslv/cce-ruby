# WHY: JavaScript and TypeScript share one ES-module specifier grammar, so the
#      rule for turning a specifier string into an import name is identical for
#      both. Keeping it here (inside the packs namespace, never in core) lets the
#      two packs share it without the engine learning either language (SPEC-V2 §2).
# WHAT: The `import … from "spec"` → import-name rule for ES modules.
# RESPONSIBILITIES:
#   - Drop leading "./" / "../" relative prefixes.
#   - Keep a scoped package whole ("@scope/pkg"); otherwise take the first path
#     segment ("./store" → "store", "@scope/pkg" → "@scope/pkg").

module CCE
  module Packs
    module EsModules
      module_function

      # @param spec [String] the raw module specifier (quotes already stripped)
      # @return [String, nil]
      def first_segment(spec)
        s = spec.to_s.sub(%r{\A(?:\.\./|\./)+}, "")
        parts = s.split("/").reject(&:empty?)
        return nil if parts.empty?
        return "#{parts[0]}/#{parts[1]}" if parts[0].start_with?("@") && parts[1]

        parts[0]
      end
    end
  end
end
