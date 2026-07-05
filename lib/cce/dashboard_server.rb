# WHY: `cce dashboard` must serve the App over HTTP, but ONLY on the loopback
#      interface (127.0.0.1), read-only and self-contained — never exposing the
#      log to the network (DASHBOARD-SPEC §6, SECURITY threat model).
# WHAT: A thin WEBrick wrapper that binds one loopback port and forwards every
#       request to a Dashboard::App, copying its Response back to the client.
# RESPONSIBILITIES:
#   - Bind 127.0.0.1 on the requested port (0 => an ephemeral port for tests).
#   - Route ALL paths through the App (a single root mount is the catch-all).
#   - Expose the bound port / URL and a clean start/stop for tests.
#   - Deliberately NOT compute metrics (App) or render HTML (Page).

require "webrick"
require_relative "metrics"
require_relative "dashboard_app"

module CCE
  module Dashboard
    class Server
      def initialize(app:, host: "127.0.0.1", port: Metrics::DEFAULT_DASHBOARD_PORT)
        @app = app
        @host = host
        @requested_port = port
        @http = build_webrick
        @running = false
      end

      # The actual bound port (meaningful even when 0 was requested).
      def bound_port
        @http.listeners.first.addr[1]
      end

      def url
        "http://#{@host}:#{bound_port}/"
      end

      def running?
        @running
      end

      # Blocking. Serves until #stop (or a signal) shuts the server down.
      def start
        @running = true
        @http.start
      ensure
        @running = false
      end

      def stop
        @http.shutdown
      end

      private

      def build_webrick
        server = WEBrick::HTTPServer.new(
          BindAddress: @host,
          Port: @requested_port,
          Logger: WEBrick::Log.new(File::NULL),
          AccessLog: []
        )
        server.mount_proc("/") { |req, res| dispatch(req, res) }
        server
      end

      def dispatch(req, res)
        response = @app.call(req.path)
        res.status = response.status
        res["Content-Type"] = response.content_type
        res.body = response.body
      end
    end
  end
end
