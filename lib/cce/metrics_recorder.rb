# WHY: Each `search`/`index`/`feedback` must append exactly one well-formed event
#      stamped with a wall-clock `ts` and a unique `id`. Centralising construction
#      keeps the event schema (DASHBOARD-SPEC §2) in one place and — because the
#      clock and id source are injected — makes it fully testable.
# WHAT: Builds the three event kinds, computes the derived `search` fields
#       (baseline/served/saved/ratio/scores/flags), and appends via an EventLog.
# RESPONSIBILITIES:
#   - Own the event field set and the search-metrics derivation (DASHBOARD-SPEC §2.1).
#   - Honour the enabled gate for auto-metrics (search/index); feedback is explicit
#     and always recorded.
#   - Deliberately NOT own persistence mechanics (EventLog) or aggregation.

require_relative "metrics"
require_relative "metrics_event_log"

module CCE
  module Metrics
    class Recorder
      def initialize(log:, clock: SystemClock.new, id_source: RandomIdSource.new, enabled: true)
        @log = log
        @clock = clock
        @id_source = id_source
        @enabled = enabled
      end

      def enabled?
        @enabled
      end

      # Append a `search` event (DASHBOARD-SPEC §2.1). `results` is the returned
      # result list (each with :file_path, :token_count, :score); `file_token_counts`
      # maps file_path => whole-file token count for the baseline (SPEC §3).
      # @return [Hash, nil] the appended event, or nil when metrics are disabled.
      def record_search(query:, top_k:, graph_enabled:, embedder:, results:, file_token_counts:, latency_ms:)
        return nil unless @enabled

        served = results.sum { |r| r[:token_count].to_i }
        distinct_files = results.map { |r| r[:file_path] }.uniq
        baseline = distinct_files.sum { |f| file_token_counts[f].to_i }
        saved = [0, baseline - served].max
        ratio = baseline.zero? ? 0.0 : saved.to_f / baseline

        result_count = results.length
        top_score = result_count.zero? ? 0.0 : results.first[:score].to_f
        top_kind = result_count.zero? ? "" : results.first[:kind].to_s
        mean_score = result_count.zero? ? 0.0 : results.sum { |r| r[:score].to_f } / result_count
        empty = result_count.zero?
        low_confidence = result_count.positive? && top_score < LOW_CONFIDENCE_THRESHOLD

        event = base_event("search").merge(
          "query" => query,
          "top_k" => top_k,
          "graph_enabled" => graph_enabled,
          "embedder" => embedder,
          "result_count" => result_count,
          "baseline_tokens" => baseline,
          "served_tokens" => served,
          "tokens_saved" => saved,
          "savings_ratio" => ratio,
          "top_score" => top_score,
          "top_kind" => top_kind,
          "mean_score" => mean_score,
          "empty" => empty,
          "low_confidence" => low_confidence,
          "latency_ms" => latency_ms.to_f
        )
        @log.append(event)
        event
      end

      # Append an `index` event (DASHBOARD-SPEC §2.2).
      # @return [Hash, nil] the appended event, or nil when metrics are disabled.
      def record_index(files_indexed:, chunks:, index_bytes:, duration_ms:, embedder:, full:)
        return nil unless @enabled

        event = base_event("index").merge(
          "files_indexed" => files_indexed,
          "chunks" => chunks,
          "index_bytes" => index_bytes,
          "duration_ms" => duration_ms.to_f,
          "embedder" => embedder,
          "full" => full
        )
        @log.append(event)
        event
      end

      # Append a `feedback` event (DASHBOARD-SPEC §2.3). Explicit user action, so
      # it is recorded regardless of the auto-metrics enabled gate.
      # @return [Hash] the appended event.
      def record_feedback(target_id:, helpful:, note: "")
        event = base_event("feedback").merge(
          "target_id" => target_id,
          "helpful" => helpful,
          "note" => note.to_s
        )
        @log.append(event)
        event
      end

      private

      def base_event(kind)
        {
          "schema" => SCHEMA,
          "event" => kind,
          "ts" => @clock.now_iso8601,
          "id" => @id_source.next_id
        }
      end
    end
  end
end
