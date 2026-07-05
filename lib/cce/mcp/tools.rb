# WHY: The three tools are the cross-language contract (SPEC-MCP §Tools): their
#      names, JSON input schemas, and output SHAPE must be byte-for-byte the same
#      in cce-ruby and cce-rust, so an agent gets identical tools regardless of
#      which engine backs the server. Isolating the contract here makes that
#      parity auditable at a glance.
# WHAT: The tool catalogue (`tools/list`) and the dispatcher (`tools/call`) that
#       turns a validated call into an MCP `content` result over a Context.
# RESPONSIBILITIES:
#   - Declare context_search / index_status / record_feedback with the EXACT
#     spec schemas and steering descriptions.
#   - Validate arguments, invoke the Context, and format the text `content`.
#   - Map a missing index to a friendly message (never an error/crash).
#   - Deliberately NOT own retrieval, persistence, or JSON-RPC framing.

require_relative "../numeric_format"
require_relative "../config"

module CCE
  module MCP
    module Tools
      module_function

      CONTEXT_SEARCH_DESCRIPTION =
        "PREFERRED tool for any question about THIS project's code. Use INSTEAD OF " \
        "reading or grepping files to locate functions, understand behaviour, or " \
        "answer 'where is X / how does Y work'. Returns the most relevant code " \
        "chunks (file:line + kind) from a hybrid vector + BM25 index, so you don't " \
        "pay tokens for whole files. Reserve file reads for opening a specific path " \
        "this tool points you to."

      MISSING_INDEX_MESSAGE =
        "This project is not indexed yet. Run `cce index` (or `cce index --workspace` " \
        "for a multi-codebase ecosystem) to build the index, then retry."

      # The full tool catalogue for `tools/list` (SPEC-MCP §Tools — exact schemas).
      def list
        [context_search_tool, index_status_tool, record_feedback_tool]
      end

      def context_search_tool
        {
          "name" => "context_search",
          "description" => CONTEXT_SEARCH_DESCRIPTION,
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "query" => { "type" => "string" },
              "top_k" => { "type" => "integer", "default" => 8 },
              "package" => { "type" => "string",
                             "description" => "scope to one workspace member (optional)" },
              "no_graph" => { "type" => "boolean", "default" => false },
              "max_tokens" => { "type" => "integer",
                                "description" => "cap the returned context (optional)" }
            },
            "required" => ["query"]
          }
        }
      end

      def index_status_tool
        {
          "name" => "index_status",
          "description" => "Check whether this project is indexed and how fresh it is.",
          "inputSchema" => { "type" => "object", "properties" => {} }
        }
      end

      def record_feedback_tool
        {
          "name" => "record_feedback",
          "description" => "Record whether a prior `context_search` result was helpful, " \
                           "to improve the quality signal on the dashboard.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "query_id" => { "type" => "string" },
              "helpful" => { "type" => "boolean" },
              "note" => { "type" => "string" }
            },
            "required" => %w[query_id helpful]
          }
        }
      end

      # Dispatch a `tools/call`. Returns an MCP result: { content:[{type,text}], isError: }.
      def call(context, name, arguments)
        args = arguments || {}
        case name
        when "context_search" then call_context_search(context, args)
        when "index_status"   then call_index_status(context, args)
        when "record_feedback" then call_record_feedback(context, args)
        else
          error_result("unknown tool: #{name}")
        end
      end

      # ---- context_search ------------------------------------------------------

      def call_context_search(context, args)
        query = args["query"]
        return error_result("context_search requires a non-empty 'query'") if blank?(query)

        top_k = positive_int(args["top_k"], 8)
        graph = !truthy(args["no_graph"])
        package = args["package"]
        max_tokens = args["max_tokens"].is_a?(Integer) && args["max_tokens"].positive? ? args["max_tokens"] : nil

        out = context.search(query, top_k: top_k, graph_enabled: graph, package: package)
        return text_result(MISSING_INDEX_MESSAGE) unless out[:indexed]

        text_result(format_search(out[:results], out[:query_id], max_tokens: max_tokens))
      end

      def format_search(results, query_id, max_tokens:)
        return "No results. #{feedback_hint(query_id)}".strip if results.empty?

        lines = []
        budget = max_tokens
        results.each do |r|
          break if budget && budget <= 0

          lines << header_line(r)
          lines << body_for(r, budget)
          budget -= r[:token_count].to_i if budget
        end
        lines << ""
        lines << "query_id: #{query_id}" if query_id
        lines << feedback_hint(query_id) if query_id
        lines.join("\n")
      end

      def header_line(r)
        pkg = r[:package] ? "#{r[:package]} · " : ""
        "#{r[:rank]}. [#{NumericFormat.fmt6(r[:score])}] " \
          "#{pkg}#{r[:file_path]}:#{r[:start_line]}-#{r[:end_line]} " \
          "(#{r[:chunk_type]}/#{r[:kind]})"
      end

      # Return the chunk body, truncated to the remaining token budget if capped.
      def body_for(r, budget)
        body = r[:content].to_s
        return body if budget.nil? || r[:token_count].to_i <= budget

        chars = [budget, 0].max * Config::CHARS_PER_TOKEN
        "#{body[0, chars]}…"
      end

      def feedback_hint(query_id)
        return "" unless query_id

        "Rate this with record_feedback(query_id: \"#{query_id}\", helpful: true|false)."
      end

      # ---- index_status --------------------------------------------------------

      def call_index_status(context, _args)
        text_result(format_status(context.index_status))
      end

      def format_status(st)
        return "Not indexed. #{MISSING_INDEX_MESSAGE}" unless st[:indexed]

        lines = []
        lines << (st[:workspace] ? "Workspace index" : "Index status")
        lines << "  chunks:     #{st[:chunk_count]}"
        lines << "  files:      #{st[:file_count]}"
        lines << "  store:      #{st[:store_path]}"
        lines << "  embedder:   #{st[:embedder]}" if st[:embedder]
        lines << "  languages:  #{kv(st[:by_language])}" if st[:by_language]
        lines << "  kinds:      #{kv(st[:by_kind])}" if st[:by_kind]
        lines << "  indexed:    #{st[:last_indexed]}" if st[:last_indexed]
        append_workspace_members(lines, st) if st[:workspace]
        append_sync(lines, st[:sync])
        lines.join("\n")
      end

      def append_workspace_members(lines, st)
        lines << "  members:"
        Array(st[:members]).each do |m|
          status = m[:indexed] ? "#{m[:files]} files, #{m[:chunks]} chunks" : "(not indexed)"
          lines << "    #{m[:name]} [#{m[:type]}]: #{status}"
        end
        lines << "  edges:      #{Array(st[:edges]).length}"
      end

      def append_sync(lines, sync)
        return unless sync

        lines << "  source:     #{sync[:source]}#{sync[:sha] ? " (#{sync[:sha][0, 12]})" : ''}"
        return unless sync[:configured]

        lines << "  sync:       configured (auto_pull=#{sync[:auto_pull] ? 'on' : 'off'})"
        lines << "  remote:     #{format_remote_latest(sync[:remote_latest])}"
        lines << "  behind:     #{behind_label(sync[:behind_remote])}"
      end

      def format_remote_latest(val)
        case val
        when nil then "(none)"
        when :unreachable then "(unreachable)"
        else val[0, 12]
        end
      end

      def behind_label(behind)
        case behind
        when true then "yes — a newer index is available (run `cce sync pull --latest`)"
        when false then "no — up to date with remote"
        else "(unknown)"
        end
      end

      # ---- record_feedback -----------------------------------------------------

      def call_record_feedback(context, args)
        query_id = args["query_id"]
        return error_result("record_feedback requires 'query_id'") if blank?(query_id)
        return error_result("record_feedback requires a boolean 'helpful'") unless [true, false].include?(args["helpful"])

        context.record_feedback(query_id: query_id, helpful: args["helpful"], note: args["note"].to_s)
        verdict = args["helpful"] ? "helpful" : "not helpful"
        text_result("Recorded feedback for #{query_id}: #{verdict}. Thanks — this feeds the dashboard quality signal.")
      end

      # ---- result helpers ------------------------------------------------------

      def text_result(text)
        { "content" => [{ "type" => "text", "text" => text }], "isError" => false }
      end

      def error_result(text)
        { "content" => [{ "type" => "text", "text" => text }], "isError" => true }
      end

      def kv(hash)
        hash.map { |k, v| "#{k}=#{v}" }.join(", ")
      end

      def blank?(val)
        val.nil? || (val.is_a?(String) && val.strip.empty?)
      end

      def truthy(val)
        val == true
      end

      def positive_int(val, default)
        val.is_a?(Integer) && val.positive? ? val : default
      end
    end
  end
end
