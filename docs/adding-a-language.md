# Adding a language

CCE's language support is a **pluggable pack architecture**: the core engine holds
zero language-specific knowledge and resolves each file to a `LanguagePack`
through a registry. Adding a language is therefore small and self-contained:

> **Add one pack file → register it → make `cce packs --validate` pass.**
> No edits to the core chunker, importer, retriever, or store.

This guide walks the whole loop, then works a full example.

## The `LanguagePack` interface

A pack subclasses `CCE::Packs::Base` (`lib/cce/packs/base.rb`) and declares:

| Member | What it is |
|---|---|
| `name` | unique lowercase id, e.g. `"go"` |
| `extensions` | the extensions it claims, leading dot + lowercase, e.g. `[".go"]` |
| `grammar_name` | the tree-sitter grammar name to load (e.g. `"go"`) |
| `function_types` | AST node types that become `function` chunks |
| `class_types` | AST node types that become `class` chunks |
| `import_node_types` | the node types `extract_imports` inspects (so the validator can check them) |
| `extract_imports(root, source)` | ordered, de-duplicated import names |
| `sample` | a small self-test snippet in this language |
| `expected` | what `sample` must produce: min function/class counts, required `kind`s, exact `imports` |

`Base` gives you `grammar` (loads `grammar_name` via `Grammars`) and protected
tree-walk helpers (`walk`, `node_text`, `each_child`, `first_child_of_type`).

## Steps

### 1. Confirm the grammar is available

The bundled `tree_sitter_language_pack` gem ships prebuilt dylibs. Check your
grammar loads:

```ruby
require "cce"
CCE::Grammars.language("go")   # => #<TreeSitter::Language ...> (nil if unavailable)
```

If it returns `nil`, the grammar is not in the pack — that is the first thing the
grammar-binding validator will tell you.

### 2. Pick the node types **from the grammar, not from memory**

Node-type spellings vary between grammars (`function_definition` in C but
`function_declaration` in Go). Parse a snippet and print the node types instead of
guessing:

```ruby
lang = CCE::Grammars.language("go")
parser = TreeSitter::Parser.new
parser.language = lang
tree = parser.parse_string(nil, File.read("example.go").b)
seen = Hash.new(0)
walk = ->(n) { seen[n.type.to_s] += 1; (0...n.child_count).each { |i| walk.call(n.child(i)) } }
walk.call(tree.root_node)
pp seen.sort
```

Note which types are the function definitions and which are the type/class-like
declarations, and which node wraps each import. (If you get a spelling wrong, the
validator's "did you mean" will point you at the closest real kind — so this step
is a fast path, not a hard requirement.)

### 3. Write the sample and its expected result

The `sample` is both the pack's self-test **and**, when it is one of the shipped
conformance languages, a byte-exact fixture under `test/fixture/samples/`. Keep it
tiny and unambiguous — enough to exercise ≥ the declared minimum function/class
counts, every required `kind`, and each import shape.

`expected` is hand-derived: read your own sample and count.

### 4. Register the pack

Add the class to `CCE::Packs::SHIPPED` in `lib/cce/packs.rb`. Registration itself
rejects a duplicate extension (Layer-1), so a clash fails loudly at startup.

### 5. Run the validators and read the diagnostics

```sh
bundle exec bin/cce packs --validate
```

Every diagnostic names the pack, the offending member, the problem, and — where
possible — the fix. Iterate until the pack is `ok`. Then add a test that iterates
your pack's `expected` (the CI gate in `test/pack_validator_test.rb` already does
this for every registered pack).

## Worked example: a `go` pack

```ruby
# lib/cce/packs/go.rb
require_relative "base"

module CCE
  module Packs
    class Go < Base
      def name = "go"
      def extensions = [".go"]
      def grammar_name = "go"
      def function_types = %w[function_declaration method_declaration]
      def class_types = %w[type_declaration]
      def import_node_types = %w[import_spec interpreted_string_literal]

      def extract_imports(root_node, source)
        bytes = source.b
        names = []
        walk(root_node) do |node|
          next unless node.type.to_s == "import_spec"

          str = first_child_of_type(node, "interpreted_string_literal")
          next unless str

          spec = node_text(str, bytes).gsub(/\A"|"\z/, "")
          seg = spec.split("/").last
          names << seg unless seg.nil? || seg.empty?
        end
        names.uniq
      end

      def sample
        <<~GO
          package main

          import "fmt"

          type Greeter struct {
              name string
          }

          func hello(g Greeter) string {
              return fmt.Sprintf("hi %s", g.name)
          }
        GO
      end

      def expected
        Expected.new(
          min_functions: 1, min_classes: 1,
          kinds: %w[function_declaration type_declaration],
          imports: ["fmt"]
        )
      end
    end
  end
end
```

Register it (`lib/cce/packs.rb`):

```ruby
require_relative "packs/go"
SHIPPED = [Python, JavaScript, Ruby, Rust, TypeScript, C, Go].freeze
```

Then:

```sh
bundle exec bin/cce packs --validate
#   ok    go
```

### What the diagnostics look like when it is wrong

If you misspell a node kind, Layer 2 catches it:

```
[pack:go] class_types: "type_declaraton" is not a node kind in tree-sitter-go.
          Did you mean: "type_declaration"?
```

If the pack is structurally valid but wired to the wrong type, Layer 3 catches it
by actually running the sample:

```
[pack:go] produced 0 class chunk(s) from its sample; expected at least 1.
          Check class_types = ["struct_type"].
```

If import extraction drifts:

```
[pack:go] imports mismatch: extracted ["fmt", "fmt"] but expected ["fmt"]
          — check extract_imports and dedupe.
```

That loop — write, validate, read the fix, repeat — is the whole point: the
safety rail turns "add a language" into a checklist a machine can grade.
