# WHY: The metrics/dashboard feature is delivered through the CLI: `search`
#      records events and prints a query-id, `index` records + persists whole-file
#      token counts, `feedback` resolves into the log, `dashboard` serves it
#      (DASHBOARD-SPEC §5, §6). Metrics failure must never break a command.
# WHAT: Pins the CLI metrics wiring end-to-end over the fixture corpus.
# RESPONSIBILITIES: Guard event append on real commands, query-id output,
#       `--no-metrics`, feedback resolution, whole-file baseline, dashboard serve.

require_relative "test_helper"
require "json"
require "open3"
require "net/http"

class CLIMetricsTest < Minitest::Test
  include TestSupport

  def capture(argv)
    out = StringIO.new
    err = StringIO.new
    code = CCE::CLI.run(argv, out: out, err: err)
    [code, out.string, err.string]
  end

  def metrics_path(dir)
    File.join(dir, ".cce", "metrics.jsonl")
  end

  def read_events(dir)
    CCE::Metrics::EventLog.new(metrics_path(dir)).read[:events]
  end

  def test_index_records_event_and_persists_file_tokens
    with_tmpdir do |dir|
      write_fixture(dir)
      code, = capture(["index", dir])
      assert_equal 0, code

      events = read_events(dir)
      idx = events.find { |e| e["event"] == "index" }
      refute_nil idx
      assert_equal 3, idx["files_indexed"]
      assert_equal 7, idx["chunks"]
      assert_operator idx["index_bytes"], :>, 0

      # Whole-file token counts persisted (SPEC §3): token_count(whole file).
      store_path = File.join(dir, ".cce", "index.db")
      store = CCE::Store.open(store_path)
      begin
        fc = store.file_token_counts
        expected = CCE::Chunker.token_count(File.read(File.join(dir, "auth.py")))
        assert_equal expected, fc["auth.py"]
      ensure
        store.close
      end
    end
  end

  def test_search_records_event_and_prints_query_id
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      code, out, = capture(["search", "hash password", "--dir", dir, "--no-graph"])
      assert_equal 0, code
      assert_match(/query-id:\s*[0-9a-f]{12}/, out)
      assert_match(/cce feedback/, out)

      search_events = read_events(dir).select { |e| e["event"] == "search" }
      assert_equal 1, search_events.length
      ev = search_events.first
      assert_equal "hash password", ev["query"]
      assert_operator ev["baseline_tokens"], :>, 0
    end
  end

  def test_search_baseline_is_sum_of_distinct_file_whole_file_tokens
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      code, out, = capture(["search", "hash password", "--dir", dir, "--no-graph", "--json"])
      assert_equal 0, code
      payload = JSON.parse(out)
      query_id = payload["query_id"]
      refute_nil query_id
      result_files = payload["results"].map { |r| r["file_path"] }.uniq

      store = CCE::Store.open(File.join(dir, ".cce", "index.db"))
      fc = store.file_token_counts
      store.close
      expected_baseline = result_files.sum { |f| fc[f].to_i }

      ev = read_events(dir).find { |e| e["id"] == query_id }
      assert_equal expected_baseline, ev["baseline_tokens"]
    end
  end

  def test_search_json_carries_query_id
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      code, out, = capture(["search", "process payment", "--dir", dir, "--no-graph", "--json"])
      assert_equal 0, code
      payload = JSON.parse(out)
      assert payload.is_a?(Hash)
      assert_match(/\A[0-9a-f]{12}\z/, payload["query_id"])
      assert payload["results"].is_a?(Array)
      assert_equal 1, payload["results"].first["rank"]
    end
  end

  def test_no_metrics_suppresses_search_and_index_events
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir, "--no-metrics"])
      code, = capture(["search", "hash", "--dir", dir, "--no-graph", "--no-metrics"])
      assert_equal 0, code
      assert_equal [], read_events(dir)
    end
  end

  def test_search_survives_unwritable_metrics_path
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      # Point metrics at an impossible path; search must still succeed.
      blocker = File.join(dir, "blocker")
      File.write(blocker, "x")
      bad = File.join(blocker, "sub", "metrics.jsonl")
      code, out, = capture(["search", "hash password", "--dir", dir, "--no-graph",
                            "--metrics", bad])
      assert_equal 0, code
      assert_match(/auth\.py/, out)
    end
  end

  def test_feedback_records_and_resolves
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      _c, out, = capture(["search", "hash password", "--dir", dir, "--no-graph", "--json"])
      query_id = JSON.parse(out)["query_id"]

      code, fout, = capture(["feedback", query_id, "--helpful", "--dir", dir])
      assert_equal 0, code
      assert_match(/recorded/i, fout)

      fb = read_events(dir).select { |e| e["event"] == "feedback" }
      assert_equal 1, fb.length
      assert_equal query_id, fb.first["target_id"]
      assert_equal true, fb.first["helpful"]
    end
  end

  def test_feedback_requires_exactly_one_polarity
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      code, _o, err = capture(["feedback", "someid", "--dir", dir])
      assert_equal 2, code
      assert_match(/--helpful|--not-helpful/, err)
    end
  end

  def test_feedback_unknown_id_still_records_with_warning
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      code, _o, err = capture(["feedback", "ffffffffffff", "--not-helpful", "--dir", dir])
      assert_equal 0, code
      assert_match(/warning/i, err)
      fb = read_events(dir).select { |e| e["event"] == "feedback" }
      assert_equal 1, fb.length
      assert_equal false, fb.first["helpful"]
    end
  end

  # Full path: `cce dashboard` binds a loopback port and serves the API.
  def test_dashboard_command_serves_over_loopback
    with_tmpdir do |dir|
      write_fixture(dir)
      capture(["index", dir])
      capture(["search", "hash password", "--dir", dir, "--no-graph"])

      bin = File.expand_path("../bin/cce", __dir__)
      env = { "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__) }
      stdin, stdout, stderr, wait = Open3.popen3(
        env, "bundle", "exec", bin, "dashboard", "--dir", dir, "--port", "0", "--no-open"
      )
      begin
        url = nil
        deadline = Time.now + 20
        while Time.now < deadline
          line = stdout.gets
          break if line.nil?
          if line =~ %r{(http://127\.0\.0\.1:\d+/)}
            url = Regexp.last_match(1)
            break
          end
        end
        refute_nil url, "dashboard did not print a URL"

        health = Net::HTTP.get_response(URI("#{url}api/health"))
        assert_equal "200", health.code
        assert_equal "ok", JSON.parse(health.body)["status"]
      ensure
        Process.kill("TERM", wait.pid) rescue nil
        wait.join
        [stdin, stdout, stderr].each(&:close)
      end
    end
  end
end
