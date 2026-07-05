# WHY: The workspace dashboard rolls up every member's north-stars AND breaks them
#      down per package (§7). Because the aggregator is pure, federation is just
#      "concatenate tagged events + add by_package"; the roll-up must equal the flat
#      aggregate over all members' events, and by_package must partition it.
# WHAT: Unit tests for CCE::Workspace::Dashboard.aggregate + App.

require_relative "test_helper"

class WorkspaceDashboardTest < Minitest::Test
  include TestSupport

  NOW = "2026-07-05T12:00:00Z"

  def search_event(member, ts:, saved:, ratio:)
    {
      "schema" => CCE::Metrics::SCHEMA, "event" => "search", "ts" => ts,
      "id" => "#{member}#{saved}", "query" => "q", "result_count" => 1,
      "tokens_saved" => saved, "savings_ratio" => ratio, "top_score" => 0.9,
      "top_kind" => "method", "empty" => false, "low_confidence" => false
    }
  end

  def member_events
    [
      { member: "app", events: [
        search_event("app", ts: NOW, saved: 100, ratio: 0.5),
        search_event("app", ts: NOW, saved: 300, ratio: 0.7)
      ] },
      { member: "billing", events: [
        search_event("billing", ts: NOW, saved: 200, ratio: 0.6)
      ] }
    ]
  end

  def test_rollup_totals_equal_flat_aggregate
    agg = CCE::Workspace::Dashboard.aggregate(member_events, now: NOW, price: 3.0)
    assert_equal 3, agg[:totals][:searches]
    assert_equal 600, agg[:totals][:tokens_saved]
  end

  def test_by_package_breakdown
    agg = CCE::Workspace::Dashboard.aggregate(member_events, now: NOW, price: 3.0)
    by = agg[:by_package]
    # Canonical cross-engine shape: an ARRAY of { package, … }, sorted by package.
    assert_kind_of Array, by
    assert_equal %w[app billing], by.map { |p| p[:package] }
    app = by.find { |p| p[:package] == "app" }
    billing = by.find { |p| p[:package] == "billing" }
    assert_equal 2, app[:searches]
    assert_equal 400, app[:tokens_saved]
    assert_in_delta 0.6, app[:mean_savings_ratio], 1e-9
    assert_equal 1, billing[:searches]
    assert_equal 200, billing[:tokens_saved]
    # v2.4: per-member retrieval quality (mean rank-1 score over non-empty searches).
    assert_in_delta 0.9, app[:mean_top_score], 1e-9
    assert_in_delta 0.9, billing[:mean_top_score], 1e-9
  end

  def test_by_package_sum_equals_total
    agg = CCE::Workspace::Dashboard.aggregate(member_events, now: NOW, price: 3.0)
    total = agg[:by_package].sum { |p| p[:tokens_saved] }
    assert_equal agg[:totals][:tokens_saved], total
  end

  def test_app_serves_federated_metrics_and_health
    with_workspace_fixture do |root|
      manifest = CCE::Workspace::Manifest.detect(root)
      manifest.write(root)
      # Write one search event under each member's .cce/metrics.jsonl.
      manifest.members.first(2).each do |m|
        mpath = CCE::Workspace.member_metrics_path(root, m)
        FileUtils.mkdir_p(File.dirname(mpath))
        File.write(mpath, JSON.generate(search_event(m.name, ts: NOW, saved: 50, ratio: 0.5)) + "\n")
      end
      app = CCE::Workspace::Dashboard::App.new(
        root: root, manifest: manifest, clock: CCE::Metrics::FixedClock.new(NOW)
      )
      metrics = JSON.parse(app.call("/api/metrics").body)
      assert_equal 2, metrics["totals"]["searches"]
      assert_kind_of Array, metrics["by_package"]
      assert(metrics["by_package"].any? { |p| p["package"] == "app" })

      health = JSON.parse(app.call("/api/health").body)
      assert_equal "ok", health["status"]
      assert_equal 3, health["members"]
      assert_equal 2, health["events"]

      assert_equal 200, app.call("/").status
      assert_equal 404, app.call("/nope").status
    end
  end
end
