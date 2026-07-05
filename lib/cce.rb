# WHY: A single require point so tests, the CLI, and tooling load the whole
#      engine consistently and in dependency order.
# WHAT: The top-level CCE namespace loader.
# RESPONSIBILITIES:
#   - Require every library module in an order that satisfies dependencies.
#   - Own no logic itself.

module CCE
  VERSION = "1.0.0"
end

require_relative "cce/config"
require_relative "cce/numeric_format"
require_relative "cce/tokenizer"
require_relative "cce/hashing"
require_relative "cce/embedder"
require_relative "cce/grammars"
require_relative "cce/chunker"
require_relative "cce/vector_store"
require_relative "cce/keyword_store"
require_relative "cce/graph_store"
require_relative "cce/retriever"
require_relative "cce/walker"
require_relative "cce/store"
require_relative "cce/ollama_embedder"
require_relative "cce/indexer"
require_relative "cce/conformance"
require_relative "cce/bench"
require_relative "cce/cli"
