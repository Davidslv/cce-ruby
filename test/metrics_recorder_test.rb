# WHY: Every `search`/`index`/`feedback` must append a well-formed event with a
#      deterministic clock + id source so the behaviour is testable and the log
#      schema is exact (DASHBOARD-SPEC §2, §8).
# WHAT: Pins the derived search fields (baseline/served/saved/ratio/scores/flags),
#       index and feedback events, and the `--no-metrics` suppression.
# RESPONSIBILITIES: Guard event construction + the enabled gate.

require_relative "test_helper"

class MetricsRecorderTest < Minitest::Test
  include TestSupport

  def build(dir, enabled: true, id: "abcabcabcabc", ts: "2026-07-05T12:00:00Z")
    log = CCE::Metrics::EventLog.new(File.join(dir, "metrics.jsonl"))
    recorder = CCE::Metrics::Recorder.new(
      log: log,
      clock: CCE::Metrics::FixedClock.new(ts),
      id_source: CCE::Metrics::SequenceIdSource.new([id]),
      enabled: enabled
    )
    [log, recorder]
  end

  def sample_results
    [
      { file_path: "a.py", token_count: 10, score: 0.9 },
      { file_path: "a.py", token_count: 8,  score: 0.7 },
      { file_path: "b.py", token_count: 5,  score: 0.5 }
    ]
  end

  def test_record_search_builds_exact_event
    with_tmpdir do |dir|
      log, rec = build(dir)
      event = rec.record_search(
        query: "login", top_k: 5, graph_enabled: true, embedder: "hash",
        results: sample_results, file_token_counts: { "a.py" => 100, "b.py" => 50 },
        latency_ms: 5.0
      )

      assert_equal "cce.metrics/v1", event["schema"]
      assert_equal "search", event["event"]
      assert_equal "2026-07-05T12:00:00Z", event["ts"]
      assert_equal "abcabcabcabc", event["id"]
      assert_equal "login", event["query"]
      assert_equal 5, event["top_k"]
      assert_equal true, event["graph_enabled"]
      assert_equal "hash", event["embedder"]
      assert_equal 3, event["result_count"]
      assert_equal 150, event["baseline_tokens"]        # 100 + 50 over distinct files
      assert_equal 23, event["served_tokens"]           # 10 + 8 + 5
      assert_equal 127, event["tokens_saved"]           # 150 - 23
      assert_in_delta 127.0 / 150.0, event["savings_ratio"], 1e-12
      assert_in_delta 0.9, event["top_score"], 1e-12
      assert_in_delta 0.7, event["mean_score"], 1e-12   # (0.9+0.7+0.5)/3
      assert_equal false, event["empty"]
      assert_equal false, event["low_confidence"]
      assert_in_delta 5.0, event["latency_ms"], 1e-12

      # Persisted to the log as a JSON line.
      assert_equal 1, log.read[:events].length
    end
  end

  def test_missing_file_token_entry_contributes_zero
    with_tmpdir do |dir|
      _log, rec = build(dir)
      event = rec.record_search(
        query: "q", top_k: 5, graph_enabled: false, embedder: "hash",
        results: [{ file_path: "b.py", token_count: 5, score: 0.9 }],
        file_token_counts: { "a.py" => 100 }, latency_ms: 1.0
      )
      assert_equal 0, event["baseline_tokens"] # b.py absent -> 0
      assert_equal 0, event["tokens_saved"]    # max(0, 0 - 5)
      assert_in_delta 0.0, event["savings_ratio"], 1e-12
    end
  end

  def test_low_confidence_flag
    with_tmpdir do |dir|
      _log, rec = build(dir)
      event = rec.record_search(
        query: "q", top_k: 5, graph_enabled: false, embedder: "hash",
        results: [{ file_path: "a.py", token_count: 5, score: 0.2 }],
        file_token_counts: { "a.py" => 100 }, latency_ms: 1.0
      )
      assert_equal true, event["low_confidence"] # result_count>0 and top<0.30
      assert_in_delta 0.2, event["top_score"], 1e-12
    end
  end

  def test_empty_search
    with_tmpdir do |dir|
      _log, rec = build(dir)
      event = rec.record_search(
        query: "zzz", top_k: 5, graph_enabled: false, embedder: "hash",
        results: [], file_token_counts: {}, latency_ms: 2.0
      )
      assert_equal 0, event["result_count"]
      assert_equal true, event["empty"]
      assert_equal false, event["low_confidence"]
      assert_equal 0, event["baseline_tokens"]
      assert_equal 0, event["served_tokens"]
      assert_in_delta 0.0, event["top_score"], 1e-12
      assert_in_delta 0.0, event["mean_score"], 1e-12
    end
  end

  def test_no_metrics_suppresses_search_write
    with_tmpdir do |dir|
      log, rec = build(dir, enabled: false)
      result = rec.record_search(
        query: "q", top_k: 5, graph_enabled: false, embedder: "hash",
        results: sample_results, file_token_counts: {}, latency_ms: 1.0
      )
      assert_nil result
      assert_equal 0, log.read[:events].length
    end
  end

  def test_record_index_event
    with_tmpdir do |dir|
      _log, rec = build(dir)
      event = rec.record_index(
        files_indexed: 231, chunks: 1728, index_bytes: 123_456,
        duration_ms: 740.0, embedder: "hash", full: true
      )
      assert_equal "index", event["event"]
      assert_equal 231, event["files_indexed"]
      assert_equal 1728, event["chunks"]
      assert_equal 123_456, event["index_bytes"]
      assert_in_delta 740.0, event["duration_ms"], 1e-12
      assert_equal "hash", event["embedder"]
      assert_equal true, event["full"]
    end
  end

  def test_record_feedback_event_always_records
    with_tmpdir do |dir|
      # enabled:false must NOT suppress explicit feedback.
      log, rec = build(dir, enabled: false, id: "000000000009")
      event = rec.record_feedback(target_id: "aaaaaaaaaaaa", helpful: true, note: "great")
      assert_equal "feedback", event["event"]
      assert_equal "aaaaaaaaaaaa", event["target_id"]
      assert_equal true, event["helpful"]
      assert_equal "great", event["note"]
      assert_equal "000000000009", event["id"]
      assert_equal 1, log.read[:events].length
    end
  end
end
