# WHY: The dashboard and its JSON API are just views over one PURE function that
#      turns the event log into KPIs, two north-stars (savings + quality), a daily
#      series, and current-vs-prior deltas. Because it is pure (no wall-clock, no
#      randomness), it is exactly testable and both language implementations must
#      reproduce the §4.1 anchor identically (DASHBOARD-SPEC §4).
# WHAT: `aggregate(events, now:, price:)` -> the §4 aggregate (minus generated_ts).
# RESPONSIBILITIES:
#   - Partition events into the current/prior 7-day windows around `now`.
#   - Compute totals, the savings & quality north-stars with directions, the daily
#     series, and the recent-searches table with feedback resolution.
#   - Apply the spec's rounding (6dp ratios/scores, 2dp cost) at OUTPUT only.
#   - Deliberately NOT read the clock or the filesystem (that is the caller's job).

require "time"
require_relative "metrics"
require_relative "numeric_format"

module CCE
  module Metrics
    module Aggregator
      module_function

      WINDOW_SECONDS = TREND_WINDOW_DAYS * 24 * 60 * 60

      # @param events [Array<Hash>] parsed log events (string keys)
      # @param now [Time, String] the "now" instant (injected; pure)
      # @param price [Numeric] USD per 1M input tokens
      # @return [Hash] the §4 aggregate with symbol keys (no generated_ts)
      def aggregate(events, now:, price:)
        now_t = now.is_a?(Time) ? now.utc : Time.parse(now.to_s).utc

        searches  = events.select { |e| e["event"] == "search" }
        indexes   = events.select { |e| e["event"] == "index" }
        feedbacks = events.select { |e| e["event"] == "feedback" }

        cur_lo   = now_t - WINDOW_SECONDS
        prior_lo = now_t - (2 * WINDOW_SECONDS)

        cur_searches   = in_window(searches, cur_lo, now_t)
        prior_searches = in_window(searches, prior_lo, cur_lo)
        cur_feedback   = in_window(feedbacks, cur_lo, now_t)
        prior_feedback = in_window(feedbacks, prior_lo, cur_lo)

        {
          schema: SCHEMA,
          totals: totals(searches, indexes, feedbacks, price),
          north_star: {
            savings: savings_north_star(cur_searches, prior_searches),
            quality: quality_north_star(cur_searches, prior_searches, cur_feedback, prior_feedback)
          },
          series: { daily: daily_series(searches, feedbacks) },
          recent_searches: recent_searches(searches, feedbacks)
        }
      end

      # ---- windows -------------------------------------------------------------

      # Events with lo <= ts < hi (inclusive lower, exclusive upper).
      def in_window(events, lo, hi)
        events.select do |e|
          t = ts(e)
          t && t >= lo && t < hi
        end
      end

      def ts(event)
        Time.parse(event["ts"]).utc
      rescue StandardError
        nil
      end

      # ---- totals --------------------------------------------------------------

      def totals(searches, indexes, feedbacks, price)
        tokens_saved = searches.sum { |s| s["tokens_saved"].to_i }
        helpful = feedbacks.count { |f| f["helpful"] == true }
        not_helpful = feedbacks.count { |f| f["helpful"] == false }
        {
          searches: searches.length,
          indexes: indexes.length,
          feedback: feedbacks.length,
          tokens_saved: tokens_saved,
          cost_saved_usd: round2(tokens_saved / 1_000_000.0 * price),
          mean_savings_ratio: r6(mean_savings_ratio(searches)),
          helpful: helpful,
          not_helpful: not_helpful,
          helpful_rate: rate_or_nil(helpful, not_helpful)
        }
      end

      # ---- north-star A: savings ----------------------------------------------

      def savings_north_star(current, prior)
        cur_mean = mean_savings_ratio(current)
        prior_mean = mean_savings_ratio(prior)
        delta = cur_mean - prior_mean
        {
          current: savings_window(current, cur_mean),
          prior: savings_window(prior, prior_mean),
          delta_ratio: r6(delta),
          direction: direction(delta)
        }
      end

      def savings_window(searches, mean)
        {
          searches: searches.length,
          tokens_saved: searches.sum { |s| s["tokens_saved"].to_i },
          mean_savings_ratio: r6(mean)
        }
      end

      # ---- north-star B: quality ----------------------------------------------

      def quality_north_star(cur_searches, prior_searches, cur_feedback, prior_feedback)
        cur_top = mean_top_score(cur_searches)
        prior_top = mean_top_score(prior_searches)
        delta = cur_top - prior_top
        {
          current: quality_window(cur_searches, cur_feedback, cur_top),
          prior: quality_window(prior_searches, prior_feedback, prior_top),
          delta_top_score: r6(delta),
          direction: direction(delta)
        }
      end

      def quality_window(searches, feedback, mean_top)
        helpful = feedback.count { |f| f["helpful"] == true }
        not_helpful = feedback.count { |f| f["helpful"] == false }
        {
          mean_top_score: r6(mean_top),
          empty_rate: r6(empty_rate(searches)),
          low_conf_rate: r6(low_conf_rate(searches)),
          helpful_rate: rate_or_nil(helpful, not_helpful)
        }
      end

      # ---- daily series --------------------------------------------------------

      def daily_series(searches, feedbacks)
        dates = (searches + feedbacks).filter_map { |e| date_of(e) }.uniq.sort
        dates.map do |date|
          day_searches = searches.select { |s| date_of(s) == date }
          day_feedback = feedbacks.select { |f| date_of(f) == date }
          {
            date: date,
            searches: day_searches.length,
            tokens_saved: day_searches.sum { |s| s["tokens_saved"].to_i },
            mean_savings_ratio: r6(mean_savings_ratio(day_searches)),
            mean_top_score: r6(mean_top_score(day_searches)),
            empty_rate: r6(empty_rate(day_searches)),
            low_conf_rate: r6(low_conf_rate(day_searches)),
            helpful: day_feedback.count { |f| f["helpful"] == true },
            not_helpful: day_feedback.count { |f| f["helpful"] == false }
          }
        end
      end

      def date_of(event)
        t = ts(event)
        t&.strftime("%Y-%m-%d")
      end

      # ---- recent searches -----------------------------------------------------

      def recent_searches(searches, feedbacks)
        resolved = resolve_feedback(feedbacks)
        sorted = searches.sort_by { |s| [ts(s) || Time.at(0), s["id"].to_s] }.reverse
        sorted.first(RECENT_SEARCHES_LIMIT).map do |s|
          {
            ts: s["ts"],
            id: s["id"],
            query: s["query"],
            result_count: s["result_count"].to_i,
            tokens_saved: s["tokens_saved"].to_i,
            savings_ratio: r6(s["savings_ratio"].to_f),
            top_score: r6(s["top_score"].to_f),
            empty: s["result_count"].to_i.zero?,
            feedback: resolved[s["id"]] || "none"
          }
        end
      end

      # Latest feedback (by ts) per target_id wins.
      def resolve_feedback(feedbacks)
        map = {}
        feedbacks.sort_by { |f| ts(f) || Time.at(0) }.each do |f|
          map[f["target_id"]] = f["helpful"] ? "helpful" : "not_helpful"
        end
        map
      end

      # ---- shared measures -----------------------------------------------------

      def mean_savings_ratio(searches)
        return 0.0 if searches.empty?

        searches.sum { |s| s["savings_ratio"].to_f } / searches.length
      end

      def mean_top_score(searches)
        non_empty = searches.select { |s| s["result_count"].to_i.positive? }
        return 0.0 if non_empty.empty?

        non_empty.sum { |s| s["top_score"].to_f } / non_empty.length
      end

      def empty_rate(searches)
        return 0.0 if searches.empty?

        searches.count { |s| s["result_count"].to_i.zero? }.to_f / searches.length
      end

      def low_conf_rate(searches)
        return 0.0 if searches.empty?

        searches.count { |s| s["low_confidence"] == true }.to_f / searches.length
      end

      def rate_or_nil(helpful, not_helpful)
        total = helpful + not_helpful
        return nil if total.zero?

        r6(helpful.to_f / total)
      end

      def direction(delta)
        return "up" if delta > DIRECTION_EPSILON
        return "down" if delta < -DIRECTION_EPSILON

        "flat"
      end

      # ---- rounding ------------------------------------------------------------

      # 6dp ratios/scores/rates, half away from zero (via NumericFormat).
      def r6(x)
        v = NumericFormat.round6(x)
        v == 0.0 ? 0.0 : v # collapse -0.0
      end

      # 2dp cost, half away from zero.
      def round2(x)
        v = x.round(2)
        v == 0.0 ? 0.0 : v
      end
    end
  end
end
