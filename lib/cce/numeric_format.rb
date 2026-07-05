# WHY: Cross-language floating point can differ in the last ULP. To make
#      rankings and emitted scores reproducible everywhere, the spec mandates a
#      single rounding rule and a single tie-break (SPEC §5.3, §8.3).
# WHAT: Round-half-away-from-zero to 6 decimals, a fixed 6-decimal string
#       formatter, and a stable sort helper keyed on rounded score then chunk_id.
# RESPONSIBILITIES:
#   - round6: deterministic 6-decimal rounding (half away from zero).
#   - fmt6: fixed "%.6f" string of a rounded value (no negative zero).
#   - sort_by_score_desc: the canonical (score desc, chunk_id asc) ordering.

module CCE
  module NumericFormat
    module_function

    # Round half away from zero to 6 decimal places. Ruby's Float#round already
    # rounds half away from zero, so we lean on it and re-round defensively.
    def round6(x)
      x.round(6)
    end

    # Fixed 6-decimal string of an already-meaningful score. We round first to
    # guarantee the printed digits match the comparison value, and normalise
    # "-0.000000" to "0.000000".
    def fmt6(x)
      r = round6(x)
      r = 0.0 if r == 0.0 # collapse -0.0
      format("%.6f", r)
    end

    # Canonical ordering used everywhere scores are ranked: by rounded score
    # descending, breaking ties by chunk_id ascending (lexicographic hex).
    # @param items [Array] each responding to the score/id blocks
    def sort_by_score_desc(items, score:, id:)
      items.sort_by { |it| [-round6(score.call(it)), id.call(it)] }
    end
  end
end
