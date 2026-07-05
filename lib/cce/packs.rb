# WHY: The engine needs exactly one place that knows which packs ship and can
#      build the registry the core resolves files through (SPEC-V2 §1.1). This is
#      the ONLY file that enumerates the shipped languages; adding a language is a
#      one-line edit here plus a new pack file — no core edits (SPEC-V2 §1).
# WHAT: Requires every pack and constructs the default PackRegistry, with the
#       cheap fail-fast Layer-1 checks run at construction (SPEC-V2 §5, surface 3).
# RESPONSIBILITIES:
#   - Enumerate and register the shipped packs (order = registration order).
#   - Fail fast on a duplicate extension or an unloadable grammar.
#   - Deliberately own no chunking, ranking, or per-language node knowledge.

require_relative "pack_registry"
require_relative "packs/python"
require_relative "packs/javascript"
require_relative "packs/ruby"
require_relative "packs/rust"
require_relative "packs/typescript"
require_relative "packs/c"

module CCE
  module Packs
    # The shipped packs, in registration order.
    SHIPPED = [Python, JavaScript, Ruby, Rust, TypeScript, C].freeze

    module_function

    # Build a fresh registry of all shipped packs. Registration itself rejects a
    # duplicate extension (Layer-1).
    def default_registry
      reg = PackRegistry.new
      SHIPPED.each { |klass| reg.register(klass.new) }
      reg
    end

    # Cheap fail-fast checks (SPEC-V2 §5): duplicate extension (already enforced
    # at registration) and unloadable grammar. Raises with a clear message rather
    # than letting the engine silently mis-chunk.
    def fail_fast!(reg)
      reg.all.each do |pack|
        next unless pack.grammar.nil?

        raise "[pack:#{pack.name}] grammar #{pack.grammar_name.inspect} failed to load — " \
              "it is missing from the bundled grammars (prefetch tree-sitter-#{pack.grammar_name})."
      end
      reg
    end
  end
end
