# WHY: A single require point so tests, the CLI, and tooling load the whole
#      engine consistently and in dependency order.
# WHAT: The top-level CCE namespace loader + the process-wide pack registry.
# RESPONSIBILITIES:
#   - Require every library module in an order that satisfies dependencies.
#   - Own the memoised default LanguagePack registry (fail-fast on construction).
#   - Own no other logic itself.

module CCE
  VERSION = "2.0.0"

  @registry = nil

  module_function

  # The process-wide LanguagePack registry (SPEC-V2 §1.1). Built once, with the
  # cheap Layer-1 fail-fast checks run at construction so a broken pack set is a
  # loud startup error, never a silent mis-chunk.
  def registry
    @registry ||= Packs.fail_fast!(Packs.default_registry)
  end

  # Swap in a registry (used by tests and by single-pack validation harnesses).
  def registry=(reg)
    @registry = reg
  end

  # Drop the memoised registry so the next access rebuilds it.
  def reset_registry!
    @registry = nil
  end
end

require_relative "cce/config"
require_relative "cce/numeric_format"
require_relative "cce/tokenizer"
require_relative "cce/hashing"
require_relative "cce/embedder"
require_relative "cce/grammars"
require_relative "cce/pack_validator"
require_relative "cce/packs"
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
require_relative "cce/metrics"
require_relative "cce/metrics_event_log"
require_relative "cce/metrics_recorder"
require_relative "cce/metrics_aggregator"
require_relative "cce/dashboard_page"
require_relative "cce/dashboard_app"
require_relative "cce/dashboard_server"
require_relative "cce/cli"
