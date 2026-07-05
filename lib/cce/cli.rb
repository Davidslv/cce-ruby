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
require_relative "workspace"
require_relative "sync"

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
      when "workspace"   then cmd_workspace(argv)
      when "sync"        then cmd_sync(argv)
      when "help", "--help", "-h", nil then print_help; 0
      else
        @err.puts "unknown command: #{cmd}"
        print_help
        2
      end
    rescue Workspace::Error => e
      @err.puts "error: #{e.message}"
      1
    rescue Sync::Error => e
      @err.puts "error: #{e.message}"
      1
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
      allow_secrets = false
      workspace = false
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--embedder NAME") { |v| embedder = v }
        o.on("--metrics PATH") { |v| metrics = v }
        o.on("--no-metrics") { no_metrics = true }
        o.on("--allow-secrets") { allow_secrets = true }
        o.on("--workspace") { workspace = true }
      end
      rest = parser.parse(argv)
      return cmd_index_workspace(rest, embedder: embedder, allow_secrets: allow_secrets, no_metrics: no_metrics) if workspace

      dir = rest.shift
      return usage_error("index requires a <dir>") unless dir
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)

      if allow_secrets
        @err.puts "warning: --allow-secrets is set; secret protection is DISABLED " \
                  "(sensitive files are read and secrets are stored verbatim)"
      end

      store ||= default_store_for(dir)
      summary = Indexer.index(dir, store_path: store, embedder: embedder, allow_secrets: allow_secrets)
      @out.puts "Indexed #{summary[:files_indexed]} files " \
                "(#{summary[:files_skipped]} skipped, " \
                "#{summary[:sensitive_skipped]} sensitive skipped), " \
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
      workspace = false
      packages = nil
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--dir PATH") { |v| dir = v }
        o.on("--metrics PATH") { |v| metrics = v }
        o.on("--no-metrics") { no_metrics = true }
        o.on("--top-k N", Integer) { |v| top_k = v }
        o.on("--no-graph") { graph = false }
        o.on("--json") { as_json = true }
        o.on("--workspace") { workspace = true }
        o.on("--package LIST") { |v| packages = v.split(",").map(&:strip).reject(&:empty?) }
      end
      rest = parser.parse(argv)
      if workspace
        return cmd_search_workspace(rest, packages: packages, top_k: top_k, graph: graph, as_json: as_json)
      end

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
      workspace = false
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--dir PATH") { |v| dir = v }
        o.on("--workspace") { workspace = true }
      end
      rest = parser.parse(argv)
      return cmd_stats_workspace(rest) if workspace

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
      lang = nil
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--queries PATH") { |v| queries = v }
        o.on("--lang NAME") { |v| lang = v }
      end
      rest = parser.parse(argv)
      repo = rest.shift
      return usage_error("bench requires a <repo-dir>") unless repo
      return usage_error("no such directory: #{repo}") unless File.directory?(repo)

      report_path = Bench.run(repo, store_path: store, queries_file: queries, lang: lang, out: @out)
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
      workspace = false
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--dir PATH") { |v| dir = v }
        o.on("--metrics PATH") { |v| metrics = v }
        o.on("--port N", Integer) { |v| port = v }
        o.on("--no-open") { _no_open = true }
        o.on("--workspace") { workspace = true }
      end
      rest = parser.parse(argv)
      return cmd_dashboard_workspace(rest, port: port) if workspace

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

    # ---- workspace (SPEC-V2.2) -----------------------------------------------

    def cmd_workspace(argv)
      sub = argv.shift
      case sub
      when "init" then cmd_workspace_init(argv)
      when "list" then cmd_workspace_list(argv)
      else usage_error("workspace requires a subcommand: init | list")
      end
    end

    def cmd_workspace_init(argv)
      force = false
      parser = OptionParser.new { |o| o.on("--force") { force = true } }
      rest = parser.parse(argv)
      dir = rest.shift || "."
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)

      manifest = Workspace::Manifest.detect(dir)
      path = manifest.write(dir, force: force)
      @out.puts "Wrote #{path}"
      print_members(manifest.members)
      0
    end

    def cmd_workspace_list(argv)
      rest = OptionParser.new.parse(argv)
      dir = rest.shift || "."
      manifest = Workspace::Manifest.load(dir)
      @out.puts "Workspace: #{manifest.name} (#{manifest.members.length} members)"
      print_members(manifest.members)
      print_edges(Workspace::Graph.build(dir, manifest)[:edges])
      0
    end

    def cmd_index_workspace(rest, embedder:, allow_secrets:, no_metrics:)
      dir = rest.shift || "."
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)

      if allow_secrets
        @err.puts "warning: --allow-secrets is set; secret protection is DISABLED " \
                  "(sensitive files are read and secrets are stored verbatim)"
      end

      summary = Workspace::Indexer.index(dir, embedder: embedder,
                                         allow_secrets: allow_secrets, record_metrics: !no_metrics)
      @out.puts "Workspace index: #{summary[:members].length} members"
      summary[:members].each do |m|
        @out.puts "  #{m[:name]} [#{m[:type]}]: #{m[:files]} files, #{m[:chunks]} chunks"
      end
      @out.puts "Totals: #{summary[:totals][:files]} files, #{summary[:totals][:chunks]} chunks"
      @out.puts "Graph: #{summary[:graph][:edges].length} cross-member edges -> #{summary[:graph_path]}"
      0
    end

    def cmd_search_workspace(rest, packages:, top_k:, graph:, as_json:)
      query = rest.shift
      return usage_error("search requires a <query>") if query.nil? || query.strip.empty?

      dir = rest.shift || "."
      manifest = Workspace::Manifest.load(dir)
      members = Workspace::Federation.scope_members(manifest, packages)
      loaded = Workspace::Federation.load_members(dir, members)
      cross_edges = Workspace::Graph.load(dir)[:edges]
      retriever = Workspace::FederatedRetriever.new(members: loaded, cross_edges: cross_edges)
      results = retriever.search(query, top_k: top_k, graph_enabled: graph)

      query_id = Metrics::RandomIdSource.new.next_id
      if as_json
        @out.puts JSON.generate(query_id: query_id, results: results.map { |r| workspace_json_result(r) })
      else
        print_workspace_human(results)
      end
      0
    end

    def cmd_stats_workspace(rest)
      dir = rest.shift || "."
      manifest = Workspace::Manifest.load(dir)
      data = Workspace::Stats.compute(dir, manifest)
      @out.puts "Workspace: #{manifest.name}"
      data[:members].each do |m|
        status = m[:indexed] ? "#{m[:files]} files, #{m[:chunks]} chunks" : "(not indexed)"
        @out.puts "  #{m[:name]} [#{m[:type]}]: #{status}"
        kinds = m[:by_kind].sort.map { |k, c| "#{k}=#{c}" }.join(", ")
        @out.puts "    kinds: #{kinds}" unless kinds.empty?
      end
      @out.puts "Totals: #{data[:totals][:files]} files, #{data[:totals][:chunks]} chunks"
      print_edges(data[:edges])
      0
    end

    def cmd_dashboard_workspace(rest, port:)
      dir = rest.shift || "."
      manifest = Workspace::Manifest.load(dir)
      app = Workspace::Dashboard::App.new(
        root: dir, manifest: manifest, price: Metrics::DEFAULT_INPUT_PRICE_PER_MILLION
      )
      server = Dashboard::Server.new(app: app, host: "127.0.0.1", port: port)
      @out.puts "CCE workspace dashboard (read-only, loopback-only) at #{server.url}"
      @out.puts "Federating #{manifest.members.length} members from #{File.expand_path(dir)}"
      @out.puts "Press Ctrl-C to stop."
      @out.flush
      trap("INT") { server.stop }
      trap("TERM") { server.stop }
      server.start
      0
    end

    def print_members(members)
      @out.puts "Members (#{members.length}):"
      members.each do |m|
        @out.puts "  #{m.name} [#{m.type}] #{m.path} (package: #{m.package})"
      end
    end

    def print_edges(edges)
      @out.puts "Edges (#{edges.length}):"
      if edges.empty?
        @out.puts "  (none)"
      else
        edges.each { |e| @out.puts "  #{e[:from]} -> #{e[:to]} (#{e[:via]})" }
      end
    end

    def workspace_json_result(r)
      {
        rank: r[:rank],
        package: r[:package],
        chunk_id: r[:chunk_id],
        file_path: r[:file_path],
        start_line: r[:start_line],
        end_line: r[:end_line],
        chunk_type: r[:chunk_type],
        kind: r[:kind],
        score: NumericFormat.fmt6(r[:score])
      }
    end

    def print_workspace_human(results)
      if results.empty?
        @out.puts "(no results)"
        return
      end
      results.each do |r|
        @out.puts "#{NumericFormat.fmt6(r[:score])}  #{r[:package]} · " \
                  "#{r[:file_path]}:#{r[:start_line]}-#{r[:end_line]} " \
                  "(#{r[:chunk_type]}/#{r[:kind]})"
      end
    end

    # ---- sync (SPEC-SYNC) ----------------------------------------------------

    def cmd_sync(argv)
      sub = argv.shift
      case sub
      when "init"   then cmd_sync_init(argv)
      when "push"   then cmd_sync_push(argv)
      when "pull"   then cmd_sync_pull(argv)
      when "status" then cmd_sync_status(argv)
      when "verify" then cmd_sync_verify(argv)
      else usage_error("sync requires a subcommand: init | push | pull | status | verify")
      end
    end

    def cmd_sync_init(argv)
      remote = nil
      lfs = true
      repo_id = nil
      parser = OptionParser.new do |o|
        o.on("--remote URL") { |v| remote = v }
        o.on("--lfs") { lfs = true }
        o.on("--no-lfs") { lfs = false }
        o.on("--repo-id ID") { |v| repo_id = v }
      end
      rest = parser.parse(argv)
      dir = rest.shift || "."
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)
      return usage_error("sync init requires --remote <git-url>") if remote.to_s.empty?

      res = Sync::Commands.new(project_dir: dir).init(remote_url: remote, lfs: lfs, repo_id: repo_id)
      @out.puts "Configured sync remote: #{res[:remote]}"
      @out.puts "repo_id: #{res[:repo_id]}"
      @out.puts "LFS: #{res[:lfs] ? 'enabled (*.cce via git-LFS)' : 'disabled'}"
      @out.puts "Local clone: #{res[:clone_dir]}"
      @out.puts "Config: #{res[:config_path]}"
      0
    end

    def cmd_sync_push(argv)
      commit = nil
      workspace = false
      parser = OptionParser.new do |o|
        o.on("--commit SHA") { |v| commit = v }
        o.on("--workspace") { workspace = true }
      end
      rest = parser.parse(argv)
      dir = rest.shift || "."
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)
      return cmd_sync_push_workspace(dir, commit: commit) if workspace

      res = Sync::Commands.new(project_dir: dir).push(commit: commit)
      verb = res[:status] == :unchanged ? "already cached" : "pushed"
      @out.puts "#{verb} #{res[:repo_id]}@#{res[:sha][0, 12]} (#{res[:chunk_count]} chunks)"
      @out.puts "  key:      #{res[:key]}"
      @out.puts "  checksum: #{res[:checksum]}"
      0
    end

    def cmd_sync_pull(argv)
      commit = nil
      latest = false
      force = false
      workspace = false
      parser = OptionParser.new do |o|
        o.on("--commit SHA") { |v| commit = v }
        o.on("--latest") { latest = true }
        o.on("--force") { force = true }
        o.on("--workspace") { workspace = true }
      end
      rest = parser.parse(argv)
      dir = rest.shift || "."
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)
      return cmd_sync_pull_workspace(dir, commit: commit, latest: latest, force: force) if workspace

      res = Sync::Commands.new(project_dir: dir).pull(commit: commit, latest: latest, force: force)
      @out.puts "Installed cache #{res[:repo_id]}@#{res[:sha][0, 12]} (#{res[:chunk_count]} chunks) into .cce/"
      @out.puts "  checksum: #{res[:checksum]}"
      if res[:tree_matches]
        @out.puts "  working tree matches this commit — the pulled index is used as-is."
      else
        @out.puts "  note: working tree differs from this commit; run `cce index #{dir}` for a local index of your changes."
      end
      0
    end

    def cmd_sync_status(argv)
      workspace = false
      parser = OptionParser.new { |o| o.on("--workspace") { workspace = true } }
      rest = parser.parse(argv)
      dir = rest.shift || "."
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)
      return cmd_sync_status_workspace(dir) if workspace

      s = Sync::Commands.new(project_dir: dir).status
      unless s[:configured]
        @out.puts "sync: not configured (run `cce sync init --remote <git-url>`)"
        return 0
      end
      @out.puts "Remote:        #{s[:remote]}"
      @out.puts "repo_id:       #{s[:repo_id] || '(unknown)'}"
      @out.puts "HEAD:          #{s[:head] ? s[:head][0, 12] : '(not a git repo)'}#{s[:dirty] ? ' (dirty)' : ''}"
      @out.puts "Local cache:   #{s[:local_sha] ? s[:local_sha][0, 12] : '(none)'}"
      @out.puts "Remote latest: #{format_remote_latest(s[:remote_latest])}"
      @out.puts "Tree matches:  #{s[:tree_matches] ? 'yes' : 'no'}"
      0
    end

    def cmd_sync_verify(argv)
      commit = nil
      parser = OptionParser.new { |o| o.on("--commit SHA") { |v| commit = v } }
      rest = parser.parse(argv)
      dir = rest.shift || "."
      return usage_error("no such directory: #{dir}") unless File.directory?(dir)

      res = Sync::Commands.new(project_dir: dir).verify(commit: commit)
      if res[:match]
        @out.puts "verify OK: re-indexed #{res[:sha][0, 12]} matches the cached checksum"
        @out.puts "  checksum: #{res[:actual]}"
        0
      else
        @err.puts "verify FAILED for #{res[:sha][0, 12]}"
        @err.puts "  expected: #{res[:expected]}"
        @err.puts "  rebuilt:  #{res[:actual]}"
        1
      end
    end

    def format_remote_latest(val)
      case val
      when nil then "(none)"
      when :unreachable then "(unreachable)"
      else val[0, 12]
      end
    end

    # Build a per-member Commands sharing one remote (SPEC-SYNC §5 workspace).
    def sync_workspace_members(dir)
      root = File.expand_path(dir)
      manifest = Workspace::Manifest.load(root)
      base = Sync::Config.load(root)
      raise Sync::Error, "no sync remote configured (run `cce sync init --remote <git-url>`)" unless base.configured?

      remote = Sync::GitRemote.for_url(base.remote, lfs: base.lfs?)
      base_repo_id = base.repo_id || Sync::ContentAddress.normalize_repo_id(Sync::Git.origin_url(root))
      manifest.members.map do |m|
        member_repo_id = Sync.member_repo_id(base_repo_id, m.package)
        cfg = Sync::Config.new(base.data.merge("repo_id" => member_repo_id))
        cmds = Sync::Commands.new(project_dir: File.join(root, m.path), config: cfg, remote: remote)
        [m, cmds]
      end
    end

    def cmd_sync_push_workspace(dir, commit:)
      @out.puts "Workspace sync push:"
      sync_workspace_members(dir).each do |m, cmds|
        res = cmds.push(commit: commit)
        verb = res[:status] == :unchanged ? "cached" : "pushed"
        @out.puts "  #{m.name} [#{m.package}]: #{verb} @#{res[:sha][0, 12]} (#{res[:chunk_count]} chunks) #{res[:checksum][0, 12]}"
      end
      0
    end

    def cmd_sync_pull_workspace(dir, commit:, latest:, force:)
      @out.puts "Workspace sync pull:"
      sync_workspace_members(dir).each do |m, cmds|
        res = cmds.pull(commit: commit, latest: latest, force: force)
        @out.puts "  #{m.name} [#{m.package}]: installed @#{res[:sha][0, 12]} (#{res[:chunk_count]} chunks) #{res[:checksum][0, 12]}"
      end
      0
    end

    def cmd_sync_status_workspace(dir)
      @out.puts "Workspace sync status:"
      sync_workspace_members(dir).each do |m, cmds|
        s = cmds.status
        local = s[:local_sha] ? s[:local_sha][0, 12] : "(none)"
        @out.puts "  #{m.name} [#{m.package}]: local #{local} · remote #{format_remote_latest(s[:remote_latest])}"
      end
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
          cce index <dir> [--store PATH] [--embedder hash|ollama] [--no-metrics] [--allow-secrets]
          cce search <query> [--dir DIR | --store PATH] [--top-k N] [--no-graph] [--json] [--no-metrics]
          cce stats [--dir DIR | --store PATH]
          cce bench <repo-dir> [--lang ruby|rust|typescript|c] [--queries FILE] [--store PATH]
          cce packs [--validate]
          cce conformance <fixture-dir> [-o conformance.json]
          cce feedback <query-id> --helpful|--not-helpful [--note "..."] [--dir DIR | --store PATH]
          cce dashboard [--dir DIR | --store PATH] [--port N] [--metrics PATH] [--no-open]

        Workspaces (multi-codebase ecosystems):
          cce workspace init [<dir>] [--force]   detect members -> .cce/workspace.yml
          cce workspace list [<dir>]             members + cross-member edges
          cce index      --workspace [<dir>]     index each member + build graph
          cce search <query> --workspace [<dir>] [--package a,b] [--top-k N] [--no-graph] [--json]
          cce stats      --workspace [<dir>]     per-member + totals + edges
          cce dashboard  --workspace [<dir>]     roll-up + per-package breakdown

        Sync (offline-first, content-addressed cache over a git remote):
          cce sync init --remote <git-url> [--lfs|--no-lfs] [--repo-id ID] [<dir>]
          cce sync push   [--commit SHA] [--workspace] [<dir>]
          cce sync pull   [--commit SHA | --latest] [--force] [--workspace] [<dir>]
          cce sync status [--workspace] [<dir>]
          cce sync verify [--commit SHA] [<dir>]
      HELP
    end
  end
end
