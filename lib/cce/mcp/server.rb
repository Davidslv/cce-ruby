# WHY: An MCP client (Claude Code) drives the server as a subprocess, exchanging
#      newline-delimited JSON-RPC 2.0 messages over stdio (SPEC-MCP §2). The
#      framing, the handshake (initialize / notifications/initialized), and the
#      request routing (tools/list, tools/call, ping) are a fixed protocol that
#      must be exactly right and never crash on a malformed message.
# WHAT: A hand-rolled JSON-RPC 2.0 over stdio loop. No dependency: the transport
#       is line-delimited JSON, which keeps the engine offline-first and the tests
#       fully hermetic (pipe JSON to an input IO, assert the output IO).
# RESPONSIBILITIES:
#   - Read one JSON message per line; write one JSON response per request.
#   - Route MCP methods; answer requests, swallow notifications (no reply).
#   - Turn a parse error / bad request / unknown method into a JSON-RPC error,
#     and a tool raise into an isError tool result — the server never dies.
#   - Deliberately NOT own store resolution (Context) or tool logic (Tools).

require "json"
require_relative "tools"

module CCE
  module MCP
    class Server
      JSONRPC = "2.0"

      # JSON-RPC 2.0 error codes (subset we emit).
      PARSE_ERROR      = -32_700
      INVALID_REQUEST  = -32_600
      METHOD_NOT_FOUND = -32_601
      INTERNAL_ERROR   = -32_603

      # @param context [MCP::Context] the resolved, read-only session
      # @param input   [IO] JSON-RPC in  (default $stdin)
      # @param output  [IO] JSON-RPC out (default $stdout)
      # @param version [String] serverInfo.version reported at handshake
      def initialize(context:, input: $stdin, output: $stdout, version: CCE::VERSION)
        @context = context
        @input = input
        @output = output
        @version = version
      end

      # Serve until the client closes stdin (EOF). One request → one response line.
      def run
        @input.each_line do |line|
          stripped = line.strip
          next if stripped.empty?

          handle_line(stripped)
        end
      end

      private

      def handle_line(line)
        msg = parse(line)
        return respond(nil, error: rpc_error(PARSE_ERROR, "parse error")) if msg == :parse_error
        return respond(msg["id"], error: rpc_error(INVALID_REQUEST, "invalid request")) unless msg.is_a?(Hash)

        dispatch(msg)
      end

      def parse(line)
        JSON.parse(line)
      rescue JSON::ParserError
        :parse_error
      end

      # Route one message. Requests (with an id) always get a response; a
      # notification (no id) is actioned silently. Any unexpected error becomes a
      # JSON-RPC internal error rather than a crash.
      def dispatch(msg)
        id = msg["id"]
        case msg["method"]
        when "initialize"                then respond(id, result: initialize_result)
        when "notifications/initialized" then nil # notification: no reply
        when "ping"                      then respond(id, result: {})
        when "tools/list"               then respond(id, result: { "tools" => Tools.list })
        when "tools/call"               then respond(id, result: tools_call(msg))
        else
          respond(id, error: rpc_error(METHOD_NOT_FOUND, "method not found: #{msg['method']}")) if id
        end
      rescue StandardError => e
        respond(id, error: rpc_error(INTERNAL_ERROR, e.message)) if id
      end

      def initialize_result
        {
          "protocolVersion" => MCP::PROTOCOL_VERSION,
          "capabilities" => { "tools" => {} },
          "serverInfo" => { "name" => MCP::SERVER_NAME, "version" => @version }
        }
      end

      def tools_call(msg)
        params = msg["params"] || {}
        Tools.call(@context, params["name"], params["arguments"])
      end

      # Write a JSON-RPC response line. A notification (id nil) with no error is
      # silent. A parse error with no id still reports id: null per the spec.
      def respond(id, result: nil, error: nil)
        return if id.nil? && error.nil?

        payload = { "jsonrpc" => JSONRPC, "id" => id }
        error ? payload["error"] = error : payload["result"] = result
        @output.puts(JSON.generate(payload))
        @output.flush
      end

      def rpc_error(code, message)
        { "code" => code, "message" => message }
      end
    end
  end
end
