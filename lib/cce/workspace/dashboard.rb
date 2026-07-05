# WHY: The dashboard's north-stars should roll up the whole ecosystem while still
#      showing which member drives savings/searches (SPEC-V2.2 §7). Because the
#      existing aggregator is a PURE function of a flat event list, federation is
#      just "concatenate each member's events (tagged) and add a by_package section".
# WHAT: The federated aggregate + a read-only serving App (roll-up + by_package).
# RESPONSIBILITIES:
#   - Federate each member's metrics.jsonl into one §4 aggregate, tagged by member.
#   - Add a per-package breakdown (searches, tokens_saved, mean_savings_ratio).
#   - Serve `/`, `/api/metrics`, `/api/health` read-only (same posture as v1.1).
#   - Deliberately NOT read the clock/filesystem in the pure aggregate (App does).

require "json"
require_relative "../metrics"
require_relative "../metrics_event_log"
require_relative "../metrics_aggregator"
require_relative "../dashboard_page"
require_relative "../numeric_format"
require_relative "manifest"

module CCE
  module Workspace
    module Dashboard
      module_function

      # Federate members' metrics into one §4 aggregate plus a by_package section.
      # @param member_events [Array<Hash>] each { member:, events: [event-hash] }
      # @return [Hash] the §4 aggregate (symbol keys) merged with by_package
      def aggregate(member_events, now:, price:)
        all = member_events.flat_map do |me|
          me[:events].map { |e| e.merge("member" => me[:member]) }
        end
        base = Metrics::Aggregator.aggregate(all, now: now, price: price)
        base.merge(by_package: by_package(member_events))
      end

      # Per-member savings roll-up (deterministic key order: member name ascending).
      def by_package(member_events)
        member_events.sort_by { |me| me[:member].to_s }.each_with_object({}) do |me, acc|
          searches = me[:events].select { |e| e["event"] == "search" }
          mean = searches.empty? ? 0.0 : searches.sum { |s| s["savings_ratio"].to_f } / searches.length
          acc[me[:member]] = {
            searches: searches.length,
            tokens_saved: searches.sum { |s| s["tokens_saved"].to_i },
            mean_savings_ratio: r6(mean)
          }
        end
      end

      def r6(value)
        v = NumericFormat.round6(value)
        v == 0.0 ? 0.0 : v
      end

      # Read-only federated dashboard app (mirrors CCE::Dashboard::App, §7).
      class App
        Response = Struct.new(:status, :content_type, :body)

        def initialize(root:, manifest:, price: Metrics::DEFAULT_INPUT_PRICE_PER_MILLION,
                       clock: Metrics::SystemClock.new)
          @root = File.expand_path(root)
          @manifest = manifest
          @price = price
          @clock = clock
        end

        def call(path)
          case path
          when "/"            then html(CCE::Dashboard::Page::HTML)
          when "/api/metrics" then json(200, metrics_body)
          when "/api/health"  then json(200, health_body)
          else json(404, { "error" => "not found", "path" => path })
          end
        end

        private

        # Freshly read each member's log on every request (live on refresh).
        def member_events
          @manifest.members.map do |m|
            mpath = Workspace.member_metrics_path(@root, m)
            { member: m.name, events: Metrics::EventLog.new(mpath).read[:events] }
          end
        end

        def metrics_body
          agg = Dashboard.aggregate(member_events, now: @clock.now_time, price: @price)
          agg.merge(generated_ts: @clock.now_iso8601)
        end

        def health_body
          data = member_events
          {
            "status" => "ok",
            "members" => data.length,
            "events" => data.sum { |d| d[:events].length }
          }
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
end
