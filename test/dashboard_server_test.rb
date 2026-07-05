# WHY: The dashboard is a loopback-only, read-only, self-contained web server.
#      Its routing and JSON must be correct, and it must actually bind and serve
#      over an ephemeral port without any external network (DASHBOARD-SPEC §6, §8).
# WHAT: Unit tests the pure request router (App) and an integration test that
#       binds WEBrick on an ephemeral loopback port and hits every endpoint.
# RESPONSIBILITIES: Guard endpoints (/, /api/metrics, /api/health, 404).

require_relative "test_helper"
require "json"
require "net/http"
require "time"

class DashboardServerTest < Minitest::Test
  include TestSupport

  FIXTURE = File.expand_path("fixture/metrics_sample.jsonl", __dir__)

  def app
    CCE::Dashboard::App.new(
      metrics_path: FIXTURE, price: 3.00,
      clock: CCE::Metrics::FixedClock.new("2026-07-05T00:00:00Z")
    )
  end

  def test_root_returns_html
    res = app.call("/")
    assert_equal 200, res.status
    assert_match(%r{text/html}, res.content_type)
    assert_match(/Code Context Engine/i, res.body)
    assert_match(/<!doctype html>/i, res.body)
    # Fully self-contained: no external subresource loads (CDN/fonts/scripts).
    # (w3.org URIs are XML namespace identifiers, never fetched, so are allowed.)
    refute_match(%r{https?://(?!127\.0\.0\.1|localhost|www\.w3\.org)}, res.body)
    refute_match(/\b(?:src|href)\s*=\s*["']https?:/i, res.body)
  end

  def test_health_endpoint
    res = app.call("/api/health")
    assert_equal 200, res.status
    assert_match(%r{application/json}, res.content_type)
    body = JSON.parse(res.body)
    assert_equal "ok", body["status"]
    assert_equal 7, body["events"]
    assert_equal 0, body["skipped"]
  end

  def test_metrics_endpoint_returns_aggregate
    res = app.call("/api/metrics")
    assert_equal 200, res.status
    assert_match(%r{application/json}, res.content_type)
    body = JSON.parse(res.body)
    assert_equal "cce.metrics/v1", body["schema"]
    assert_equal 4, body["totals"]["searches"]
    assert body.key?("generated_ts")
    assert_equal "up", body["north_star"]["savings"]["direction"]
    # v2.4 refreshed panels are present in the served shape and offline-safe.
    assert_equal 4, body["by_source"]["cli"]["searches"]
    assert_equal 0, body["by_source"]["mcp"]["searches"]
    assert_equal 1, body["freshness"]["indexes"]
    assert_equal 0, body["secret_safety"]["sensitive_skipped"]
  end

  def test_unknown_path_is_404
    res = app.call("/does/not/exist")
    assert_equal 404, res.status
  end

  def test_binds_ephemeral_loopback_port_and_serves
    server = CCE::Dashboard::Server.new(app: app, host: "127.0.0.1", port: 0)
    thread = Thread.new { server.start }
    begin
      wait_until { server.running? }
      port = server.bound_port
      assert_operator port, :>, 0

      health = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/api/health"))
      assert_equal "200", health.code
      assert_equal "ok", JSON.parse(health.body)["status"]

      root = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
      assert_equal "200", root.code

      missing = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/nope"))
      assert_equal "404", missing.code
    ensure
      server.stop
      thread.join(5)
    end
  end

  def wait_until(timeout: 5)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    raise "server did not become ready" unless yield
  end
end
