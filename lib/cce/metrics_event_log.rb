# WHY: The dashboard is fed from PERSISTED data: an append-only JSONL log at
#      `<store-dir>/metrics.jsonl`. Writing must be best-effort (never break the
#      command that produced the event) and reading must tolerate a corrupt or
#      truncated file (DASHBOARD-SPEC §2, §2.4).
# WHAT: A tiny append/read wrapper over a JSON-lines file.
# RESPONSIBILITIES:
#   - append: serialise one event to one line; fail-open (return false, no raise).
#   - read: parse every non-blank line, skipping (and counting) malformed ones;
#     an absent file is an empty dataset, not an error.
#   - Deliberately NOT own event shape (Recorder) or aggregation (Aggregator).

require "json"
require "fileutils"

module CCE
  module Metrics
    class EventLog
      attr_reader :path

      def initialize(path)
        @path = path
      end

      # Append one event hash as a JSON line. Best-effort: on ANY error we return
      # false and never raise, so a metrics failure cannot break `search`/`index`.
      # @return [Boolean] true on success, false if the write failed.
      def append(event)
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") { |f| f.puts(JSON.generate(event)) }
        true
      rescue StandardError
        false
      end

      # Parse the log into events + a count of skipped (blank/malformed) lines.
      # @return [Hash] { events: Array<Hash>, skipped: Integer }
      def read
        events = []
        skipped = 0
        return { events: events, skipped: skipped } unless File.exist?(@path)

        File.foreach(@path) do |line|
          stripped = line.strip
          if stripped.empty?
            skipped += 1
            next
          end
          begin
            obj = JSON.parse(stripped)
          rescue JSON::ParserError
            skipped += 1
            next
          end
          if obj.is_a?(Hash) && obj["event"]
            events << obj
          else
            skipped += 1
          end
        end
        { events: events, skipped: skipped }
      rescue StandardError
        { events: events, skipped: skipped }
      end
    end
  end
end
