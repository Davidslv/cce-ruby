# WHY: The engine is only useful behind a command-line interface a user (or an
#      agent) can drive: index, search, stats, bench, conformance (SPEC §9) plus
#      the v1.1 observability commands feedback and dashboard (DASHBOARD-SPEC §5).
# WHAT: Argument parsing and command dispatch, returning a process exit code and
#       writing human/JSON output to injected IO (for testability).
# RESPONSIBILITIES:
#   - Parse each command's flags and validate inputs (friendly errors, no crash).
#   - Orchestrate Indexer/Retriever/Store/Bench/Conformance and format output.
#   - Append metrics events (best-effort) and serve the read-only dashboard.
#   - Deliberately NOT own retrieval, persistence, or aggregation logic.

require "json"
require "optparse"
require_relative "indexer"
require_relative "store"
require_relative "conformance"
require_relative "bench"
require_relative "packs"
require_relative "pack_validator"
require_relative "numeric_format"
require_relative "metrics"
require_relative "metrics_event_log"
require_relative "metrics_recorder"
require_relative "dashboard_app"
require_relative "dashboard_server"

module CCE
  class CLI
    def self.run(argv, out: $stdout, err: $stderr)
      new(out, err).run(argv)
    end

    def initialize(out, err)
      @out = out
      @err = err
    end

    def run(argv)
      cmd = argv.shift
      case cmd
      when "index"       then cmd_index(argv)
      when "search"      then cmd_search(argv)
      when "stats"       then cmd_stats(argv)
      when "bench"       then cmd_bench(argv)
      when "packs"       then cmd_packs(argv)
      when "conformance" then cmd_conformance(argv)
      when "feedback"    then cmd_feedback(argv)
      when "dashboard"   then cmd_dashboard(argv)
      when "help", "--help", "-h", nil then print_help; 0
      else
        @err.puts "unknown command: #{cmd}"
        print_help
        2
      end
    rescue Store::Error => e
      @err.puts "error: #{e.message}"
      1
    rescue OllamaEmbedder::Unreachable => e
      @err.puts "error: #{e.message}"
      1
    rescue StandardError => e
      @err.puts "error: #{e.message}"
      1
    end

    private

    def default_store_for(dir)
      File.join(File.expand_path(dir), ".cce", "index.db")
    end

    # Resolve the metrics log path (DASHBOARD-SPEC §2): an explicit --metrics wins;
    # otherwise it sits next to the store (same dir), or under <dir>/.cce/.
    def metrics_path_for(metrics: nil, store: nil, dir: nil)
      return File.expand_path(metrics) if metrics
      return File.join(File.dirname(File.expand_path(store)), Metrics::FILE) if store
      return File.join(File.expand_path(dir), ".cce", Metrics::FILE) if dir

      nil
    end

    # Build a metrics recorder over a log path. `enabled` is the --no-metrics /
    # metrics.enabled gate; the clock and id source default to the real ones (the
    # metrics subsystem is the one place wall-clock time is allowed).
    def recorder_for(metrics_path, enabled: true)
      Metrics::Recorder.new(log: Metrics::EventLog.new(metrics_path), enabled: enabled)
    end

    # ---- index ---------------------------------------------------------------

    def cmd_index(argv)
      store = nil
      embedder = "hash"
      metrics = nil
      no_metrics = false
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--embedder NAME") { |v| embedder = v }
        o.on("--metrics PATH") { |v| metrics = v }
        o.on("--no-metrics") { no_metrics = true }
      end
      rest = parser.parse(argv)
      dir = rest.shift
      return usage_error("index requires a <dir>") unless dir
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)

      store ||= default_store_for(dir)
      summary = Indexer.index(dir, store_path: store, embedder: embedder)
      @out.puts "Indexed #{summary[:files_indexed]} files " \
                "(#{summary[:files_skipped]} skipped), " \
                "#{summary[:total_chunks]} chunks in " \
                "#{format('%.3f', summary[:elapsed])}s"
      @out.puts "Store: #{summary[:store_path]}"

      mpath = metrics_path_for(metrics: metrics, store: store, dir: dir)
      recorder_for(mpath, enabled: !no_metrics).record_index(
        files_indexed: summary[:files_indexed],
        chunks: summary[:total_chunks],
        index_bytes: File.exist?(store) ? File.size(store) : 0,
        duration_ms: summary[:elapsed] * 1000.0,
        embedder: embedder,
        full: true
      )
      0
    end

    # ---- search --------------------------------------------------------------

    def cmd_search(argv)
      store = nil
      dir = nil
      metrics = nil
      no_metrics = false
      top_k = Config::DEFAULT_TOP_K
      graph = true
      as_json = false
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--dir PATH") { |v| dir = v }
        o.on("--metrics PATH") { |v| metrics = v }
        o.on("--no-metrics") { no_metrics = true }
        o.on("--top-k N", Integer) { |v| top_k = v }
        o.on("--no-graph") { graph = false }
        o.on("--json") { as_json = true }
      end
      rest = parser.parse(argv)
      query = rest.join(" ")
      return usage_error("search requires a <query>") if query.strip.empty?

      store ||= dir ? default_store_for(dir) : nil
      return usage_error("search requires --dir or --store") unless store

      retriever = Indexer.retriever_from_store(store)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = retriever.search(query, top_k: top_k, graph_enabled: graph)
      latency_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0

      # Record the search event (best-effort; never affects the result/exit code).
      mpath = metrics_path_for(metrics: metrics, store: store, dir: dir)
      event = record_search_metrics(mpath, store, query, top_k, graph, results, latency_ms) unless no_metrics
      query_id = event && event["id"]

      if as_json
        @out.puts JSON.generate(query_id: query_id, results: results.map { |r| json_result(r) })
      else
        print_human(results)
        if query_id
          @out.puts "query-id: #{query_id}  ·  rate with: " \
                    "cce feedback #{query_id} --helpful|--not-helpful"
        end
      end
      0
    end

    # Build a search event from the results + the store's whole-file token counts.
    def record_search_metrics(mpath, store, query, top_k, graph, results, latency_ms)
      file_tokens, embedder = search_context(store)
      recorder_for(mpath, enabled: true).record_search(
        query: query, top_k: top_k, graph_enabled: graph, embedder: embedder,
        results: results, file_token_counts: file_tokens, latency_ms: latency_ms
      )
    end

    # Read the whole-file token counts and embedder name from a store (best-effort).
    def search_context(store)
      s = Store.open(store)
      begin
        [s.file_token_counts, s.embedder_name]
      ensure
        s.close
      end
    rescue StandardError
      [{}, "hash"]
    end

    def json_result(r)
      {
        rank: r[:rank],
        chunk_id: r[:chunk_id],
        file_path: r[:file_path],
        start_line: r[:start_line],
        end_line: r[:end_line],
        chunk_type: r[:chunk_type],
        kind: r[:kind],
        score: NumericFormat.fmt6(r[:score])
      }
    end

    def print_human(results)
      if results.empty?
        @out.puts "(no results)"
        return
      end
      results.each do |r|
        snippet = r[:content].to_s.strip.lines.first.to_s.strip[0, 80]
        @out.puts "#{r[:rank]}. [#{NumericFormat.fmt6(r[:score])}] " \
                  "#{r[:file_path]}:#{r[:start_line]}-#{r[:end_line]} " \
                  "(#{r[:chunk_type]}/#{r[:kind]})"
        @out.puts "    #{snippet}"
      end
    end

    # ---- stats ---------------------------------------------------------------

    def cmd_stats(argv)
      store = nil
      dir = nil
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--dir PATH") { |v| dir = v }
      end
      rest = parser.parse(argv)
      store ||= dir ? default_store_for(dir) : (rest.first ? default_store_for(rest.first) : nil)
      return usage_error("stats requires --dir or --store") unless store

      s = Store.open(store)
      begin
        chunks = s.chunks
        files = chunks.map(&:file_path).uniq
        by_lang = chunks.map(&:language).tally
        by_kind = chunks.map(&:kind).tally
        avg_tokens = chunks.empty? ? 0 : chunks.sum(&:token_count).to_f / chunks.length
        @out.puts "Chunks:     #{chunks.length}"
        @out.puts "Files:      #{files.length}"
        @out.puts "Languages:  #{by_lang.sort.map { |l, c| "#{l}=#{c}" }.join(', ')}"
        @out.puts "Kinds:      #{by_kind.sort.map { |k, c| "#{k}=#{c}" }.join(', ')}"
        @out.puts "Avg tokens: #{format('%.1f', avg_tokens)}"
        @out.puts "Store size: #{s.size_bytes} bytes"
      ensure
        s.close
      end
      0
    end

    # ---- bench ---------------------------------------------------------------

    def cmd_bench(argv)
      store = nil
      queries = nil
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--queries PATH") { |v| queries = v }
      end
      rest = parser.parse(argv)
      repo = rest.shift
      return usage_error("bench requires a <repo-dir>") unless repo
      return usage_error("no such directory: #{repo}") unless File.directory?(repo)

      report_path = Bench.run(repo, store_path: store, queries_file: queries, out: @out)
      @out.puts "Wrote #{report_path}"
      0
    end

    # ---- packs ---------------------------------------------------------------

    # List registered language packs, or validate them across all three layers
    # (SPEC-V2 §5). `--validate` exits non-zero if any pack fails.
    def cmd_packs(argv)
      validate = false
      parser = OptionParser.new do |o|
        o.on("--validate") { validate = true }
      end
      parser.parse(argv)

      packs = CCE.registry.all
      return cmd_packs_validate(packs) if validate

      @out.puts "Registered language packs (#{packs.length}):"
      packs.each do |p|
        @out.puts format(
          "  %-11s %-24s grammar=%-11s fn-types=%d cls-types=%d",
          p.name, p.extensions.join(","), p.grammar_name,
          p.function_types.length, p.class_types.length
        )
      end
      0
    end

    def cmd_packs_validate(packs)
      failed = false
      @out.puts "Validating #{packs.length} packs..."
      packs.each do |p|
        diags = PackValidator.validate(p, others: packs - [p])
        if diags.empty?
          @out.puts "  ok    #{p.name}"
        else
          failed = true
          @out.puts "  FAIL  #{p.name}"
          diags.each { |d| @out.puts "        #{d}" }
        end
      end
      if failed
        @err.puts "one or more packs failed validation"
        return 1
      end
      @out.puts "All #{packs.length} packs valid."
      0
    end

    # ---- conformance ---------------------------------------------------------

    def cmd_conformance(argv)
      output = "conformance.json"
      parser = OptionParser.new do |o|
        o.on("-o PATH", "--output PATH") { |v| output = v }
      end
      rest = parser.parse(argv)
      dir = rest.shift
      return usage_error("conformance requires a <fixture-dir>") unless dir
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)

      json = Conformance.to_json(dir)
      File.write(output, json)
      @out.puts "Wrote #{output}"
      0
    end

    # ---- feedback ------------------------------------------------------------

    def cmd_feedback(argv)
      store = nil
      dir = nil
      metrics = nil
      helpful = nil
      note = ""
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--dir PATH") { |v| dir = v }
        o.on("--metrics PATH") { |v| metrics = v }
        o.on("--helpful") { helpful = true }
        o.on("--not-helpful") { helpful = false }
        o.on("--note NOTE") { |v| note = v }
      end
      rest = parser.parse(argv)
      target_id = rest.shift
      return usage_error("feedback requires a <query-id>") unless target_id
      return usage_error("feedback requires exactly one of --helpful / --not-helpful") if helpful.nil?

      mpath = metrics_path_for(metrics: metrics, store: store, dir: dir)
      return usage_error("feedback requires --dir, --store or --metrics") unless mpath

      known = feedback_target_known?(mpath, target_id)
      @err.puts "warning: no search event with id #{target_id} in the log" unless known

      recorder_for(mpath, enabled: true).record_feedback(target_id: target_id, helpful: helpful, note: note)
      @out.puts "Feedback recorded for #{target_id}: #{helpful ? 'helpful' : 'not-helpful'}"
      0
    end

    def feedback_target_known?(mpath, target_id)
      Metrics::EventLog.new(mpath).read[:events].any? do |e|
        e["event"] == "search" && e["id"] == target_id
      end
    end

    # ---- dashboard -----------------------------------------------------------

    def cmd_dashboard(argv)
      store = nil
      dir = nil
      metrics = nil
      port = Metrics::DEFAULT_DASHBOARD_PORT
      _no_open = false
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--dir PATH") { |v| dir = v }
        o.on("--metrics PATH") { |v| metrics = v }
        o.on("--port N", Integer) { |v| port = v }
        o.on("--no-open") { _no_open = true }
      end
      parser.parse(argv)

      mpath = metrics_path_for(metrics: metrics, store: store, dir: dir)
      return usage_error("dashboard requires --dir, --store or --metrics") unless mpath

      app = Dashboard::App.new(metrics_path: mpath, price: Metrics::DEFAULT_INPUT_PRICE_PER_MILLION)
      server = Dashboard::Server.new(app: app, host: "127.0.0.1", port: port)
      @out.puts "CCE dashboard (read-only, loopback-only) at #{server.url}"
      @out.puts "Serving metrics from #{mpath}"
      @out.puts "Press Ctrl-C to stop."
      @out.flush
      trap("INT") { server.stop }
      trap("TERM") { server.stop }
      server.start
      0
    end

    def usage_error(msg)
      @err.puts "error: #{msg}"
      2
    end

    def print_help
      @out.puts <<~HELP
        cce — Code Context Engine

        Usage:
          cce index <dir> [--store PATH] [--embedder hash|ollama] [--no-metrics]
          cce search <query> [--dir DIR | --store PATH] [--top-k N] [--no-graph] [--json] [--no-metrics]
          cce stats [--dir DIR | --store PATH]
          cce bench <repo-dir> [--queries FILE] [--store PATH]
          cce packs [--validate]
          cce conformance <fixture-dir> [-o conformance.json]
          cce feedback <query-id> --helpful|--not-helpful [--note "..."] [--dir DIR | --store PATH]
          cce dashboard [--dir DIR | --store PATH] [--port N] [--metrics PATH] [--no-open]
      HELP
    end
  end
end
