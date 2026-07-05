# WHY: Adding a language must be safe and self-diagnosing — a mistyped node kind
#      or a pack wired to the wrong type should fail loudly with a fix, not
#      silently mis-chunk (SPEC-V2 §5). The validator is that safety rail: three
#      escalating layers, each diagnostic naming the pack, member, problem and fix.
# WHAT: Structural, grammar-binding, and behavioural validation of a LanguagePack.
# RESPONSIBILITIES:
#   - Layer 1: structural lint (name, extensions, interface, extension-uniqueness).
#   - Layer 2: grammar-binding lint — every declared node type exists in the
#     grammar, with an edit-distance "did you mean" on a miss.
#   - Layer 3: behavioural self-test — run the pack over its sample and check
#     min function/class counts, required kinds, and exact imports.
#   - Deliberately hold NO language-specific knowledge; it only reads a pack.

require "tree_sitter"

module CCE
  module PackValidator
    # Required interface methods every pack must answer (structural lint).
    INTERFACE = %i[
      name extensions grammar_name function_types class_types
      import_node_types extract_imports sample expected
    ].freeze

    module_function

    # Validate one pack across all three layers.
    # @param pack the LanguagePack
    # @param others [Array] the other registered packs (for extension-uniqueness)
    # @return [Array<String>] diagnostics; empty means the pack is compatible.
    def validate(pack, others: [])
      diags = structural(pack, others)
      # A pack that fails structurally can't be meaningfully grammar/behaviour
      # checked (missing interface, etc.), so stop after Layer 1 in that case.
      return diags unless diags.empty?

      diags.concat(grammar_binding(pack))
      return diags unless diags.empty?

      diags.concat(behavioural(pack))
      diags
    end

    def compatible?(pack, others: [])
      validate(pack, others: others).empty?
    end

    # ---- Layer 1: structural lint --------------------------------------------

    def structural(pack, others)
      diags = []
      missing = INTERFACE.reject { |m| pack.respond_to?(m) }
      unless missing.empty?
        return ["[pack:#{safe_name(pack)}] does not implement the pack interface; " \
                "missing: #{missing.join(', ')}."]
      end

      diags << "[pack:#{pack.name}] name must be a non-empty lowercase id." if pack.name.to_s.strip.empty?

      exts = Array(pack.extensions)
      diags << "[pack:#{pack.name}] must claim at least one extension." if exts.empty?
      exts.each do |ext|
        unless ext.is_a?(String) && ext.start_with?(".") && ext == ext.downcase && ext.length > 1
          diags << %([pack:#{pack.name}] extension #{ext.inspect} must be a lowercased ) +
                   %(leading-dot string like ".rb".)
        end
      end

      claimed = {}
      others.each { |o| o.extensions.each { |e| claimed[e.downcase] = o.name } }
      exts.each do |ext|
        owner = claimed[ext.downcase]
        next unless owner

        diags << %([pack:#{pack.name}] extension "#{ext}" already claimed by pack ) +
                 %("#{owner}"; each extension maps to exactly one pack.)
      end
      diags
    end

    # ---- Layer 2: grammar-binding lint ---------------------------------------

    def grammar_binding(pack)
      grammar = pack.grammar
      if grammar.nil?
        return ["[pack:#{pack.name}] grammar #{pack.grammar_name.inspect} failed to load — " \
                "it is missing from the bundled grammars (add/prefetch tree-sitter-#{pack.grammar_name})."]
      end

      kinds = grammar_kinds(grammar)
      named = kinds.select { |k| k.match?(/\A[a-z_][a-z0-9_]*\z/) }
      diags = []
      {
        "function_types" => Array(pack.function_types),
        "class_types" => Array(pack.class_types),
        "import_node_types" => Array(pack.import_node_types)
      }.each do |member, types|
        types.each do |type|
          next if kinds.include?(type)

          diags << "[pack:#{pack.name}] #{member}: #{type.inspect} is not a node kind in " \
                   "tree-sitter-#{pack.grammar_name}.#{did_you_mean(type, named)}"
        end
      end
      diags
    end

    # ---- Layer 3: behavioural self-test --------------------------------------

    def behavioural(pack)
      grammar = pack.grammar
      return ["[pack:#{pack.name}] grammar unavailable for self-test."] if grammar.nil?

      sample = pack.sample.to_s
      root = parse(grammar, sample)
      return ["[pack:#{pack.name}] sample failed to parse."] if root.nil?

      fns = 0
      classes = 0
      present = []
      fn_types = Array(pack.function_types)
      cls_types = Array(pack.class_types)
      walk(root) do |node|
        next unless node.named?

        type = node.type.to_s
        if fn_types.include?(type)
          fns += 1
          present << type
        elsif cls_types.include?(type)
          classes += 1
          present << type
        end
      end
      present.uniq!

      exp = pack.expected
      diags = []
      if fns < exp.min_functions
        diags << "[pack:#{pack.name}] produced #{fns} function chunk(s) from its sample; " \
                 "expected at least #{exp.min_functions}. Check function_types = #{fn_types.inspect}."
      end
      if classes < exp.min_classes
        diags << "[pack:#{pack.name}] produced #{classes} class chunk(s) from its sample; " \
                 "expected at least #{exp.min_classes}. Check class_types = #{cls_types.inspect}."
      end
      missing_kinds = Array(exp.kinds).map(&:to_s) - present
      unless missing_kinds.empty?
        diags << "[pack:#{pack.name}] sample is missing expected kind(s) #{missing_kinds.inspect}; " \
                 "produced kinds #{present.inspect}."
      end

      actual_imports = safe_imports(pack, root, sample)
      if actual_imports != Array(exp.imports)
        diags << "[pack:#{pack.name}] imports mismatch: extracted #{actual_imports.inspect} " \
                 "but expected #{Array(exp.imports).inspect} — check extract_imports and dedupe."
      end
      diags
    end

    # ---- helpers -------------------------------------------------------------

    def grammar_kinds(grammar)
      (0...grammar.symbol_count).filter_map do |i|
        grammar.symbol_name(i)
      rescue StandardError
        nil
      end.uniq
    end

    def did_you_mean(type, candidates)
      ranked = candidates
               .map { |c| [levenshtein(type, c), c] }
               .select { |d, c| d <= [3, (c.length / 2)].max }
               .sort_by { |d, c| [d, c] }
               .first(3)
               .map { |_, c| c }
      return "" if ranked.empty?

      " Did you mean: #{ranked.map(&:inspect).join(', ')}?"
    end

    def levenshtein(a, b)
      return b.length if a.empty?
      return a.length if b.empty?

      prev = (0..b.length).to_a
      a.each_char.with_index do |ca, i|
        cur = [i + 1]
        b.each_char.with_index do |cb, j|
          cur << [prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1)].min
        end
        prev = cur
      end
      prev.last
    end

    def parse(grammar, source)
      parser = TreeSitter::Parser.new
      parser.language = grammar
      tree = parser.parse_string(nil, source.b)
      tree&.root_node
    rescue StandardError
      nil
    end

    def walk(node, &block)
      block.call(node)
      i = 0
      count = node.child_count
      while i < count
        walk(node.child(i), &block)
        i += 1
      end
    end

    def safe_imports(pack, root, source)
      Array(pack.extract_imports(root, source))
    rescue StandardError => e
      ["<error: #{e.class}>"]
    end

    def safe_name(pack)
      pack.respond_to?(:name) ? pack.name : pack.class.name
    rescue StandardError
      pack.class.name
    end
  end
end
