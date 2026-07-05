# WHY: The metrics event log is the persisted, append-only source of truth for
#      the dashboard. Writes must be best-effort (never break a command) and
#      reads must tolerate corruption (DASHBOARD-SPEC §2, §2.4).
# WHAT: Pins append (with injected clock + id via the Recorder is elsewhere; here
#       we test the raw log), read robustness, and fail-open behaviour.
# RESPONSIBILITIES: Guard append/read of the JSONL event log.

require_relative "test_helper"
require "json"

class MetricsEventLogTest < Minitest::Test
  include TestSupport

  def test_append_then_read_round_trip
    with_tmpdir do |dir|
      path = File.join(dir, ".cce", "metrics.jsonl")
      log = CCE::Metrics::EventLog.new(path)
      assert log.append({ "schema" => "cce.metrics/v1", "event" => "search", "id" => "abc" })
      assert log.append({ "schema" => "cce.metrics/v1", "event" => "feedback", "id" => "def" })

      data = log.read
      assert_equal 2, data[:events].length
      assert_equal 0, data[:skipped]
      assert_equal "search", data[:events][0]["event"]
      assert_equal "def", data[:events][1]["id"]
    end
  end

  def test_missing_file_is_empty_dataset
    with_tmpdir do |dir|
      log = CCE::Metrics::EventLog.new(File.join(dir, "nope", "metrics.jsonl"))
      data = log.read
      assert_equal [], data[:events]
      assert_equal 0, data[:skipped]
    end
  end

  def test_read_skips_blank_and_corrupt_lines
    with_tmpdir do |dir|
      path = File.join(dir, "metrics.jsonl")
      File.write(path, [
        '{"event":"search","id":"a"}',
        "",                       # blank
        "not json at all",        # corrupt
        '{"event":"index","id":"b","future_field":42}', # unknown field tolerated
        "   ",                    # whitespace-only
        '{"event":"feedback","id":"c"}'
      ].join("\n") + "\n")

      data = CCE::Metrics::EventLog.new(path).read
      assert_equal 3, data[:events].length
      assert_equal 3, data[:skipped] # blank + corrupt + whitespace
      assert_equal 42, data[:events][1]["future_field"]
    end
  end

  def test_append_is_fail_open_when_path_unwritable
    with_tmpdir do |dir|
      # Put a regular file where a directory would need to be, so mkdir_p fails.
      blocker = File.join(dir, "blocker")
      File.write(blocker, "x")
      log = CCE::Metrics::EventLog.new(File.join(blocker, "sub", "metrics.jsonl"))

      result = nil
      # Must never raise; returns false on failure.
      assert_silent { result = log.append({ "event" => "search" }) }
      refute result
    end
  end
end
