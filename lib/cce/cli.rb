# WHY: The engine is only useful behind a command-line interface a user (or an
#      agent) can drive: index, search, stats, bench, conformance (SPEC §9).
# WHAT: Argument parsing and command dispatch, returning a process exit code and
#       writing human/JSON output to injected IO (for testability).
# RESPONSIBILITIES:
#   - Parse each command's flags and validate inputs (friendly errors, no crash).
#   - Orchestrate Indexer/Retriever/Store/Bench/Conformance and format output.
#   - Deliberately NOT own retrieval or persistence logic.

require "json"
require "optparse"
require_relative "indexer"
require_relative "store"
require_relative "conformance"
require_relative "bench"
require_relative "numeric_format"

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
      when "conformance" then cmd_conformance(argv)
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

    # ---- index ---------------------------------------------------------------

    def cmd_index(argv)
      store = nil
      embedder = "hash"
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--embedder NAME") { |v| embedder = v }
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
      0
    end

    # ---- search --------------------------------------------------------------

    def cmd_search(argv)
      store = nil
      dir = nil
      top_k = Config::DEFAULT_TOP_K
      graph = true
      as_json = false
      parser = OptionParser.new do |o|
        o.on("--store PATH") { |v| store = v }
        o.on("--dir PATH") { |v| dir = v }
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
      results = retriever.search(query, top_k: top_k, graph_enabled: graph)

      if as_json
        @out.puts JSON.generate(results.map { |r| json_result(r) })
      else
        print_human(results)
      end
      0
    end

    def json_result(r)
      {
        rank: r[:rank],
        chunk_id: r[:chunk_id],
        file_path: r[:file_path],
        start_line: r[:start_line],
        end_line: r[:end_line],
        chunk_type: r[:chunk_type],
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
                  "(#{r[:chunk_type]})"
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
        avg_tokens = chunks.empty? ? 0 : chunks.sum(&:token_count).to_f / chunks.length
        @out.puts "Chunks:     #{chunks.length}"
        @out.puts "Files:      #{files.length}"
        @out.puts "Languages:  #{by_lang.sort.map { |l, c| "#{l}=#{c}" }.join(', ')}"
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

    def usage_error(msg)
      @err.puts "error: #{msg}"
      2
    end

    def print_help
      @out.puts <<~HELP
        cce — Code Context Engine

        Usage:
          cce index <dir> [--store PATH] [--embedder hash|ollama]
          cce search <query> [--dir DIR | --store PATH] [--top-k N] [--no-graph] [--json]
          cce stats [--dir DIR | --store PATH]
          cce bench <repo-dir> [--queries FILE] [--store PATH]
          cce conformance <fixture-dir> [-o conformance.json]
      HELP
    end
  end
end
