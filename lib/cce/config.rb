# WHY: Every scoring constant in the engine is normative (SPEC §3) and both the
#      Ruby and reference implementations must agree bit-for-bit. Centralising
#      them removes the risk of a divergent literal sneaking into an algorithm.
# WHAT: A single frozen home for all tuning constants plus lightweight config
#       loading (defaults, with optional overrides for the embedder backend).
# RESPONSIBILITIES:
#   - Own the exact normative constant values from SPEC §3.
#   - Provide a Config value object carrying runtime choices (embedder, store).
#   - Deliberately NOT own any algorithm — only the numbers they consume.

module CCE
  module Config
    EMBED_DIM             = 256
    CHARS_PER_TOKEN       = 4
    RRF_K                 = 60
    CONFIDENCE_WEIGHT     = 0.5
    FTS_BOOST_CODE_LOOKUP = 1.5
    MAX_CHUNKS_PER_FILE   = 3
    BM25_K1               = 1.2
    BM25_B                = 0.75
    CANDIDATE_MULTIPLIER  = 3
    W_VECTOR              = 0.5
    W_KEYWORD             = 0.4
    W_RECENCY             = 0.1
    PATH_PENALTY          = 0.8
    PATH_PENALTY_MARKERS  = ["tests/", "test_", "docs/", "spec", "plan"].freeze
    GRAPH_MAX_BONUS_FILES = 2
    GRAPH_BONUS_CHUNK_SCALE = 0.85
    DEFAULT_TOP_K         = 10

    # Directories excluded during the walk (SPEC §7.1). Any dotdir is also
    # excluded dynamically; these are the explicitly-named non-dot cases.
    IGNORED_DIRS = %w[node_modules venv __pycache__ dist build].freeze

    MAX_FILE_BYTES = 2 * 1024 * 1024 # 2 MB (SPEC §7.1)

    SPEC_VERSION = "1.0"

    # Extension → language resolution (SPEC §4.2).
    LANGUAGE_BY_EXT = {
      ".py"  => "python",
      ".js"  => "javascript",
      ".jsx" => "javascript",
      ".mjs" => "javascript",
      ".cjs" => "javascript"
    }.freeze
  end

  # Runtime configuration resolved from CLI flags / config file, defaulting to
  # the normative values above.
  class RuntimeConfig
    attr_reader :embedder, :store_path

    def initialize(embedder: "hash", store_path: nil)
      @embedder = embedder
      @store_path = store_path
    end
  end
end
