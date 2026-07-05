source "https://rubygems.org"

ruby ">= 3.2"

# Runtime dependencies
gem "sqlite3", "~> 2.9"                    # on-disk persistence store
gem "ruby_tree_sitter", "~> 2.1"           # tree-sitter FFI bindings for AST chunking
gem "tree_sitter_language_pack", "~> 1.12" # bundled Python/JavaScript grammars
gem "webrick", "~> 1.9"                     # minimal loopback HTTP server for `cce dashboard`

group :development, :test do
  gem "minitest", "~> 6.0"      # standard test framework (TDD)
  gem "rake", "~> 13.2"         # test task runner
  gem "simplecov", "~> 0.22"    # coverage measurement
end
