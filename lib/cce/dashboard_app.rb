# WHY: The dashboard's three endpoints are pure functions of the log + the clock:
#      routing them without a socket makes them unit-testable, and keeps the web
#      server (WEBrick) a thin transport around this logic (DASHBOARD-SPEC §6).
# WHAT: A read-only request router. `GET /` serves the self-contained page;
#       `GET /api/metrics` computes the §4 aggregate fresh on every request;
#       `GET /api/health` reports event/skip counts; anything else is 404.
# RESPONSIBILITIES:
#   - Map a request path to a Response (status, content_type, body).
#   - Recompute the aggregate from the CURRENT log each call (live on refresh).
#   - Deliberately NOT mutate anything (read-only) and NOT bind sockets (Server).

require "json"
require_relative "metrics"
require_relative "metrics_event_log"
require_relative "metrics_aggregator"
require_relative "dashboard_page"

module CCE
  module Dashboard
    class App
      Response = Struct.new(:status, :content_type, :body)

      def initialize(metrics_path:, price: Metrics::DEFAULT_INPUT_PRICE_PER_MILLION, clock: Metrics::SystemClock.new)
        @metrics_path = metrics_path
        @price = price
        @clock = clock
      end

      # @param path [String] request path (query string already stripped)
      # @return [Response]
      def call(path)
        case path
        when "/"            then html(Page::HTML)
        when "/api/metrics" then json(200, metrics_body)
        when "/api/health"  then json(200, health_body)
        else json(404, { "error" => "not found", "path" => path })
        end
      end

      private

      def log
        Metrics::EventLog.new(@metrics_path)
      end

      def metrics_body
        events = log.read[:events]
        agg = Metrics::Aggregator.aggregate(events, now: @clock.now_time, price: @price)
        agg.merge(generated_ts: @clock.now_iso8601)
      end

      def health_body
        data = log.read
        { "status" => "ok", "events" => data[:events].length, "skipped" => data[:skipped] }
      end

      def html(body)
        Response.new(200, "text/html; charset=utf-8", body)
      end

      def json(status, obj)
        Response.new(status, "application/json; charset=utf-8", JSON.generate(obj))
      end
    end
  end
end
