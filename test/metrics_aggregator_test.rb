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
    # v2.4.1: mean top-1 score over the log's non-empty searches (0.9,0.6,0.4)/3.
    assert_equal "0.633333", r6(t[:mean_top_score])
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

  # --- v2.4 dashboard-refresh panels (additive; anchor unaffected) ---

  # Pre-v2.4 fixture has no `source` on its searches, so every search must fall
  # into the "cli" bucket (before MCP shipped, all searches were human CLI).
  def test_by_source_degrades_pre_v24_to_cli
    bs = aggregate_anchor[:by_source]
    assert_equal 4, bs[:cli][:searches]
    assert_equal 53_000, bs[:cli][:tokens_saved]
    assert_equal 0, bs[:mcp][:searches]
    assert_equal 0, bs[:mcp][:tokens_saved]
  end

  def test_by_source_splits_cli_and_mcp
    events = [
      { "event" => "search", "ts" => "2026-07-04T10:00:00Z", "id" => "s1",
        "source" => "cli", "tokens_saved" => 100, "savings_ratio" => 0.5, "result_count" => 1, "top_score" => 0.9 },
      { "event" => "search", "ts" => "2026-07-04T11:00:00Z", "id" => "s2",
        "source" => "mcp", "tokens_saved" => 300, "savings_ratio" => 0.75, "result_count" => 1, "top_score" => 0.8 }
    ]
    bs = CCE::Metrics::Aggregator.aggregate(events, now: Time.utc(2026, 7, 5), price: 3.00)[:by_source]
    assert_equal 1, bs[:cli][:searches]
    assert_equal 100, bs[:cli][:tokens_saved]
    assert_equal "0.900000", r6(bs[:cli][:mean_top_score])
    assert_equal 1, bs[:mcp][:searches]
    assert_equal 300, bs[:mcp][:tokens_saved]
    assert_equal "0.750000", r6(bs[:mcp][:mean_savings_ratio])
    assert_equal "0.800000", r6(bs[:mcp][:mean_top_score])
  end

  # index_freshness reads the MOST RECENT index event (offline; no remote contact).
  def test_index_freshness_from_latest_index_event
    events = [
      { "event" => "index", "ts" => "2026-07-01T09:00:00Z", "id" => "i1",
        "source" => "local", "sha" => "oldsha000000" },
      { "event" => "index", "ts" => "2026-07-04T09:00:00Z", "id" => "i2",
        "source" => "sync-pull", "sha" => "newsha111111" }
    ]
    fr = CCE::Metrics::Aggregator.aggregate(events, now: Time.utc(2026, 7, 5), price: 3.00)[:index_freshness]
    assert_equal %i[indexes source sha indexed_ts], fr.keys
    assert_equal 2, fr[:indexes]
    assert_equal "newsha111111", fr[:sha]
    assert_equal "sync-pull", fr[:source]
    assert_equal "2026-07-04T09:00:00Z", fr[:indexed_ts]
  end

  def test_index_freshness_and_secret_safety_degrade_on_pre_v24_index
    # Anchor fixture's single index event has neither sha nor source nor skips.
    fr = aggregate_anchor[:index_freshness]
    assert_equal 1, fr[:indexes]
    assert_nil fr[:sha]
    assert_equal "local", fr[:source] # absent source defaults to local
    ss = aggregate_anchor[:secret_safety]
    assert_equal 0, ss[:sensitive_skipped]
    assert_equal 1, ss[:index_runs]
  end

  def test_secret_safety_sums_sensitive_skipped_and_counts_runs
    events = [
      { "event" => "index", "ts" => "2026-07-01T09:00:00Z", "id" => "i1", "sensitive_skipped" => 2 },
      { "event" => "index", "ts" => "2026-07-02T09:00:00Z", "id" => "i2", "sensitive_skipped" => 5 }
    ]
    ss = CCE::Metrics::Aggregator.aggregate(events, now: Time.utc(2026, 7, 5), price: 3.00)[:secret_safety]
    assert_equal 7, ss[:sensitive_skipped]
    assert_equal 2, ss[:index_runs]
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
    # v2.4 panels are present and empty-safe.
    assert_equal 0, agg[:by_source][:cli][:searches]
    assert_equal 0, agg[:by_source][:mcp][:searches]
    assert_equal 0, agg[:index_freshness][:indexes]
    assert_nil agg[:index_freshness][:sha]
    assert_nil agg[:index_freshness][:source]
    assert_equal 0, agg[:secret_safety][:sensitive_skipped]
    assert_equal 0, agg[:secret_safety][:index_runs]
  end
end
