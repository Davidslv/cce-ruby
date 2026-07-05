# WHY: The aggregator is a pure function that both language implementations must
#      evaluate identically. The §4.1 anchor over test/fixture/metrics_sample.jsonl
#      is the cross-language equivalence gate for the dashboard (DASHBOARD-SPEC §4).
# WHAT: Reproduces the anchor numbers EXACTLY, plus the empty-log case.
# RESPONSIBILITIES: Guard totals, north-stars, daily series, and recent searches.

require_relative "test_helper"
require "time"

class MetricsAggregatorTest < Minitest::Test
  include TestSupport

  FIXTURE = File.expand_path("fixture/metrics_sample.jsonl", __dir__)

  def aggregate_anchor
    events = CCE::Metrics::EventLog.new(FIXTURE).read[:events]
    CCE::Metrics::Aggregator.aggregate(
      events, now: Time.utc(2026, 7, 5, 0, 0, 0), price: 3.00
    )
  end

  # Format helpers so assertions match the spec's 6dp / 2dp presentation exactly.
  def r6(x) = format("%.6f", x)
  def r2(x) = format("%.2f", x)

  def test_schema_present
    assert_equal "cce.metrics/v1", aggregate_anchor[:schema]
  end

  def test_totals_anchor
    t = aggregate_anchor[:totals]
    assert_equal 4, t[:searches]
    assert_equal 1, t[:indexes]
    assert_equal 2, t[:feedback]
    assert_equal 53_000, t[:tokens_saved]
    assert_equal "0.16", r2(t[:cost_saved_usd])
    assert_equal "0.525000", r6(t[:mean_savings_ratio])
    assert_equal 1, t[:helpful]
    assert_equal 1, t[:not_helpful]
    assert_equal "0.500000", r6(t[:helpful_rate])
  end

  def test_north_star_savings_anchor
    s = aggregate_anchor[:north_star][:savings]
    assert_equal 3, s[:current][:searches]
    assert_equal 48_000, s[:current][:tokens_saved]
    assert_equal "0.533333", r6(s[:current][:mean_savings_ratio])
    assert_equal 1, s[:prior][:searches]
    assert_equal 5_000, s[:prior][:tokens_saved]
    assert_equal "0.500000", r6(s[:prior][:mean_savings_ratio])
    assert_equal "0.033333", r6(s[:delta_ratio])
    assert_equal "up", s[:direction]
  end

  def test_north_star_quality_anchor
    q = aggregate_anchor[:north_star][:quality]
    assert_equal "0.750000", r6(q[:current][:mean_top_score])
    assert_equal "0.333333", r6(q[:current][:empty_rate])
    assert_equal "0.000000", r6(q[:current][:low_conf_rate])
    assert_equal "0.500000", r6(q[:current][:helpful_rate])

    assert_equal "0.400000", r6(q[:prior][:mean_top_score])
    assert_equal "0.000000", r6(q[:prior][:empty_rate])
    assert_equal "0.000000", r6(q[:prior][:low_conf_rate])
    assert_nil q[:prior][:helpful_rate]

    assert_equal "0.350000", r6(q[:delta_top_score])
    assert_equal "up", q[:direction]
  end

  def test_daily_series_anchor
    daily = aggregate_anchor[:series][:daily]
    dates = daily.map { |d| d[:date] }
    assert_equal %w[2026-06-25 2026-07-01 2026-07-02 2026-07-03], dates

    d0702 = daily.find { |d| d[:date] == "2026-07-02" }
    assert_equal 2, d0702[:searches]
    assert_equal "0.500000", r6(d0702[:empty_rate])
    assert_equal 1, d0702[:helpful]

    d0703 = daily.find { |d| d[:date] == "2026-07-03" }
    assert_equal 0, d0703[:searches]
    assert_equal 1, d0703[:not_helpful]
  end

  def test_recent_searches_resolution_and_order
    rs = aggregate_anchor[:recent_searches]
    # 4 searches, newest first by ts.
    assert_equal %w[cccccccccccc bbbbbbbbbbbb aaaaaaaaaaaa dddddddddddd], rs.map { |x| x[:id] }
    by_id = rs.each_with_object({}) { |x, h| h[x[:id]] = x }
    assert_equal "helpful", by_id["aaaaaaaaaaaa"][:feedback]
    assert_equal "not_helpful", by_id["bbbbbbbbbbbb"][:feedback]
    assert_equal "none", by_id["cccccccccccc"][:feedback]
    assert_equal "none", by_id["dddddddddddd"][:feedback]
  end

  def test_empty_log_is_valid_no_data_aggregate
    agg = CCE::Metrics::Aggregator.aggregate(
      [], now: Time.utc(2026, 7, 5), price: 3.00
    )
    assert_equal "cce.metrics/v1", agg[:schema]
    assert_equal 0, agg[:totals][:searches]
    assert_equal 0, agg[:totals][:tokens_saved]
    assert_in_delta 0.0, agg[:totals][:cost_saved_usd], 1e-12
    assert_in_delta 0.0, agg[:totals][:mean_savings_ratio], 1e-12
    assert_nil agg[:totals][:helpful_rate]
    assert_equal "flat", agg[:north_star][:savings][:direction]
    assert_equal "flat", agg[:north_star][:quality][:direction]
    assert_nil agg[:north_star][:quality][:current][:helpful_rate]
    assert_equal [], agg[:series][:daily]
    assert_equal [], agg[:recent_searches]
  end
end
