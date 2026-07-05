# WHY: Claims about speed, recall, and token savings need to be measured on a
#      real repository, reproducibly, and written up (SPEC §10).
# WHAT: The benchmark runner: index a repo, time queries, compute recall and
#       token savings, and emit docs/BENCHMARKS.md.
# RESPONSIBILITIES:
#   - Index a pinned repo with the default hash embedder and time it.
#   - Measure query latency (p50/p95), Recall@5/@10, and token savings.
#   - Render a Markdown report.
#   - Deliberately NOT own the retrieval algorithm (Retriever) or CLI parsing.

require "json"
require "shellwords"
require "fileutils"
require_relative "indexer"
require_relative "store"

module CCE
  module Bench
    # Labelled query sets for the four benchmarked languages (SPEC-V2 §8):
    # query => acceptable path substrings (hit if any top-K file contains any).
    # Python/JavaScript are validated packs but are not benchmarked.
    LANGUAGE_QUERIES = {
      "ruby" => { # sinatra/sinatra
        "route matching and dispatch"       => ["base"],
        "render erb/haml template"          => ["base"],
        "session and cookies"               => ["base"],
        "mime type helpers"                 => ["base"],
        "middleware stack"                  => ["base"],
        "delegator methods"                 => ["base"],
        "handle errors and show exceptions" => ["show_exceptions"],
        "streaming responses"               => ["base"],
        "rack response building"            => ["base"],
        "url helpers"                       => ["base"]
      }.freeze,
      "rust" => { # sharkdp/hyperfine
        "run a benchmark and measure timing"       => ["benchmark"],
        "parse command line options"               => ["options"],
        "export results as json"                   => ["export"],
        "export as markdown"                       => ["export"],
        "warmup runs"                              => ["benchmark"],
        "shell spawning and command execution"     => ["command"],
        "outlier detection statistics"             => ["outlier"],
        "progress bar output"                      => ["benchmark"],
        "parameter ranges"                         => ["parameter"],
        "timing measurement"                       => ["timer"]
      }.freeze,
      "typescript" => { # pmndrs/zustand
        "create a store"               => ["vanilla"],
        "react hook to use the store"  => ["react"],
        "persist middleware"           => ["middleware"],
        "subscribe with selector"      => ["middleware"],
        "shallow equality"             => ["shallow"],
        "combine slices"               => ["middleware"],
        "devtools integration"         => ["middleware"],
        "set and get state"            => ["vanilla"],
        "immer middleware"             => ["middleware"],
        "context provider"             => ["context"]
      }.freeze,
      "c" => { # jqlang/jq
        "parse a json value"               => ["jv"],
        "builtin functions"                => ["builtin"],
        "execute bytecode"                 => ["execute"],
        "print/format json output"         => ["jv_print"],
        "lexer/tokenizer"                  => ["lexer"],
        "compile the program"              => ["compile"],
        "object and array construction"    => ["jv"],
        "decode number"                    => ["jv"],
        "main entry point"                 => ["main"],
        "unicode handling"                 => ["jv_unicode"]
      }.freeze
    }.freeze

    DEFAULT_LANG = "ruby"
    # Backwards-compatible default query set (the Ruby/sinatra corpus).
    DEFAULT_QUERIES = LANGUAGE_QUERIES.fetch(DEFAULT_LANG)

    module_function

    # @return [String] path to the written report (docs/BENCHMARKS.md)
    def run(repo, store_path: nil, queries_file: nil, out: $stdout, repeats: 5, report_path: nil, lang: nil)
      store_path ||= File.join(File.expand_path(repo), ".cce", "bench.db")
      queries = if queries_file
                  load_queries(queries_file)
                else
                  LANGUAGE_QUERIES.fetch(lang || DEFAULT_LANG, DEFAULT_QUERIES)
                end

      out.puts "Indexing #{repo} ..."
      # Benchmark the WHOLE repository exactly as `cce index` does (SPEC-V2 §8):
      # pack-matched files are AST-chunked into function/class chunks, every other
      # in-scope text file becomes a single fallback `module` chunk, under the
      # normal walk ignore rules. No bench-specific corpus filtering.
      summary = Indexer.index(repo, store_path: store_path, embedder: "hash")
      retriever = Indexer.retriever_from_store(store_path)

      latencies = []
      hits5 = 0
      hits10 = 0
      savings = []

      queries.each do |query, expected|
        results = nil
        repeats.times do
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          results = retriever.search(query, top_k: 10, graph_enabled: false)
          latencies << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
        end
        hits5 += 1 if hit?(results.first(5), expected)
        hits10 += 1 if hit?(results.first(10), expected)
        savings << token_saving(results.first(10), repo)
      end

      metrics = {
        repo: repo,
        language: lang || DEFAULT_LANG,
        commit: git_commit(repo),
        files: summary[:files_indexed],
        skipped: summary[:files_skipped],
        chunks: summary[:total_chunks],
        index_seconds: summary[:elapsed],
        chunks_per_second: summary[:elapsed].zero? ? 0 : summary[:total_chunks] / summary[:elapsed],
        p50_ms: percentile(latencies, 50),
        p95_ms: percentile(latencies, 95),
        recall5: hits5.to_f / queries.length,
        recall10: hits10.to_f / queries.length,
        token_savings: savings.empty? ? 0.0 : savings.sum / savings.length,
        query_count: queries.length,
        embedder: "hash"
      }

      report = render(metrics)
      path = report_path || File.expand_path("../../docs/BENCHMARKS.md", __dir__)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, report)
      path
    end

    def hit?(results, expected)
      results.any? { |r| expected.any? { |sub| sub.empty? || r[:file_path].include?(sub) } }
    end

    # baseline = sum of whole-file token_count over distinct result files;
    # served   = sum of result chunk token_counts. Return 1 - served/baseline.
    def token_saving(results, repo)
      return 0.0 if results.empty?

      served = results.sum { |r| r[:token_count] }
      files = results.map { |r| r[:file_path] }.uniq
      baseline = files.sum { |fp| whole_file_tokens(File.join(repo, fp)) }
      return 0.0 if baseline.zero?

      1.0 - served.to_f / baseline
    end

    def whole_file_tokens(path)
      return 1 unless File.exist?(path)

      [1, File.size(path) / Config::CHARS_PER_TOKEN].max
    end

    def percentile(samples, pct)
      return 0.0 if samples.empty?

      sorted = samples.sort
      rank = (pct / 100.0) * (sorted.length - 1)
      lo = rank.floor
      hi = rank.ceil
      return sorted[lo] if lo == hi

      sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo)
    end

    def git_commit(repo)
      out = `git -C #{repo.shellescape} rev-parse HEAD 2>/dev/null`.strip
      out.empty? ? "unknown" : out
    rescue StandardError
      "unknown"
    end

    def load_queries(path)
      # Simple "query -> substring" per line, tab or "->" separated.
      queries = {}
      File.readlines(path).each do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        q, sub = line.split(/\s*->\s*|\t/, 2)
        queries[q.strip] = [sub.to_s.strip]
      end
      queries
    end

    def render(m)
      <<~MD
        # CCE Benchmarks

        Generated by `cce bench`. Headline numbers come from the pipeline running
        against a pinned real repository with the default hashing embedder.

        ## Environment

        | Field | Value |
        |---|---|
        | Runtime | Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}) |
        | Corpus language | #{m[:language]} |
        | Embedder | #{m[:embedder]} |
        | Corpus | #{m[:repo]} |
        | Corpus commit | `#{m[:commit]}` |
        | Machine | #{`uname -mns`.strip} |

        ## Index

        | Metric | Value |
        |---|---|
        | Files indexed | #{m[:files]} |
        | Files skipped | #{m[:skipped]} |
        | Chunks | #{m[:chunks]} |
        | Wall-clock | #{format('%.3f', m[:index_seconds])} s |
        | Chunks/second | #{format('%.1f', m[:chunks_per_second])} |

        ## Query latency (#{m[:query_count]} labeled queries, repeated)

        | Metric | Value |
        |---|---|
        | p50 | #{format('%.3f', m[:p50_ms])} ms |
        | p95 | #{format('%.3f', m[:p95_ms])} ms |

        ## Retrieval quality

        | Metric | Value |
        |---|---|
        | Recall@5 | #{format('%.1f', m[:recall5] * 100)}% |
        | Recall@10 | #{format('%.1f', m[:recall10] * 100)}% |
        | Mean token savings | #{format('%.1f', m[:token_savings] * 100)}% |

        ## Interpretation

        With the deterministic hashing embedder retrieval is essentially lexical,
        so recall reflects keyword overlap between each query and the target
        file's identifiers — exactly as the spec anticipates. Token savings are
        large because the engine returns a handful of function/class chunks
        instead of whole files: a top-10 result set serves a small fraction of the
        tokens a reader would otherwise load. Latency is dominated by exact
        brute-force cosine over every chunk plus BM25 scoring (no ANN index, by
        design); for a repo of this size that is on the order of tens of
        milliseconds per query — comfortably interactive. Recall and token-savings
        numbers are a
        function of the corpus and algorithm only, so they should match the other
        clean-room implementation exactly; latency is language-dependent.
      MD
    end
  end
end
