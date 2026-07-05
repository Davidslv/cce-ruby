# WHY: The dashboard/observability feature (DASHBOARD-SPEC v1.1) is the ONE place
#      the engine is allowed to use wall-clock time and unique ids. To keep tests
#      deterministic, that non-determinism must be injectable, and the metrics
#      constants must live in one normative home (DASHBOARD-SPEC §0, §1).
# WHAT: The `CCE::Metrics` namespace: its normative constants plus the injectable
#       clock and id sources (a real pair for production, fixed pairs for tests).
# RESPONSIBILITIES:
#   - Own the DASHBOARD-SPEC §1 constants (schema tag, file name, thresholds).
#   - Provide SystemClock/FixedClock/SequenceClock (ISO-8601 UTC, second precision).
#   - Provide RandomIdSource/SequenceIdSource (12 lowercase-hex chars).
#   - Deliberately NOT own event construction, aggregation, or serving.

require "securerandom"
require "time"

module CCE
  module Metrics
    # Normative constants (DASHBOARD-SPEC §1).
    SCHEMA                          = "cce.metrics/v1"
    FILE                            = "metrics.jsonl"
    LOW_CONFIDENCE_THRESHOLD        = 0.30
    TREND_WINDOW_DAYS               = 7
    DEFAULT_DASHBOARD_PORT          = 8787
    DEFAULT_INPUT_PRICE_PER_MILLION = 3.00
    RECENT_SEARCHES_LIMIT           = 20
    DIRECTION_EPSILON               = 1e-9

    # Real wall clock — ISO-8601 UTC at second precision (e.g. 2026-07-05T13:04:11Z).
    class SystemClock
      def now_iso8601
        Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end

      # A Time object for the aggregator's window maths.
      def now_time
        Time.now.utc
      end
    end

    # A clock frozen at one instant, for deterministic tests.
    class FixedClock
      def initialize(iso)
        @iso = iso
      end

      def now_iso8601
        @iso
      end

      def now_time
        Time.parse(@iso).utc
      end
    end

    # A clock that yields a fixed sequence of instants, one per call.
    class SequenceClock
      def initialize(isos)
        @isos = isos.dup
      end

      def now_iso8601
        @isos.shift
      end
    end

    # Real unique id: 12 lowercase-hex chars (6 random bytes).
    class RandomIdSource
      def next_id
        SecureRandom.hex(6)
      end
    end

    # A deterministic id sequence, for tests.
    class SequenceIdSource
      def initialize(ids)
        @ids = ids.dup
      end

      def next_id
        @ids.shift
      end
    end
  end
end
