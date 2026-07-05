source "https://rubygems.org"

ruby ">= 3.2"

# Runtime dependencies
gem "sqlite3", "~> 2.9"                    # on-disk persistence store
gem "ruby_tree_sitter", "~> 2.1"           # tree-sitter FFI bindings for AST chunking
gem "tree_sitter_language_pack", "~> 1.12" # bundled Python/JavaScript grammars

group :development, :test do
  gem "minitest", "~> 5.25"     # standard test framework (TDD)
  gem "rake", "~> 13.2"         # test task runner
  gem "simplecov", "~> 0.22"    # coverage measurement
end
