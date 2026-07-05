# WHY: An agent (Claude Code, Cursor, …) is far more useful when CCE is a native
#      tool it auto-invokes than when we hope it shells out to `cce search`
#      (SPEC-MCP §1). This file is the single namespace + require point for the
#      Model Context Protocol server, keeping the pinned protocol version and the
#      server identity in one normative place so both language engines agree.
# WHAT: The CCE::MCP namespace + its constants + the subsystem require order.
# RESPONSIBILITIES:
#   - Pin the MCP protocol version and the server name/identity (the wire contract).
#   - Resolve the default store path the same way the CLI does (SPEC-MCP §2).
#   - Require the MCP subsystem in dependency order.
#   - Own no protocol/tool/init logic itself (those live below).

module CCE
  module MCP
    # The MCP protocol revision we speak. Pinned to the current stable spec
    # revision at build time (https://modelcontextprotocol.io) so the handshake
    # is deterministic and identical across the Ruby and Rust engines.
    PROTOCOL_VERSION = "2025-06-18"

    # Server identity reported in the `initialize` handshake (SPEC-MCP §2).
    SERVER_NAME = "cce"

    # Raised for user-facing MCP/init errors (bad flags, unresolvable store). The
    # CLI turns these into a clear non-zero message; the server itself never
    # crashes on a bad request — it replies with a JSON-RPC error instead.
    class Error < StandardError; end

    module_function

    # The default store path for a project dir — identical to the CLI's rule so
    # `cce mcp` and `cce search` resolve the same index (SPEC-MCP §2).
    def default_store_for(dir)
      File.join(File.expand_path(dir || "."), ".cce", "index.db")
    end
  end
end

require_relative "mcp/context"
require_relative "mcp/tools"
require_relative "mcp/server"
require_relative "mcp/init"
