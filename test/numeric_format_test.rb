# WHY: Deterministic rounding and tie-breaking underpin cross-implementation
#      equivalence; the rules must be exact (SPEC §5.3, §8.3).
# WHAT: Pins round-half-away-from-zero, fixed 6-decimal formatting, and the
#       canonical score-desc/id-asc ordering.
# RESPONSIBILITIES: Guard NumericFormat.

require_relative "test_helper"

class NumericFormatTest < Minitest::Test
  def test_round6_half_away_from_zero
    assert_in_delta 0.123457, CCE::NumericFormat.round6(0.1234565), 1e-12
    assert_in_delta(-0.123457, CCE::NumericFormat.round6(-0.1234565), 1e-12)
  end

  def test_fmt6_always_six_decimals
    assert_equal "0.100000", CCE::NumericFormat.fmt6(0.1)
    assert_equal "1.000000", CCE::NumericFormat.fmt6(1.0)
    assert_equal "0.123457", CCE::NumericFormat.fmt6(0.12345678)
  end

  def test_fmt6_no_negative_zero
    assert_equal "0.000000", CCE::NumericFormat.fmt6(-0.0)
    assert_equal "0.000000", CCE::NumericFormat.fmt6(-0.0000001)
  end

  def test_sort_by_score_desc_ties_break_on_id
    items = [
      { id: "bbbb", s: 0.5 },
      { id: "aaaa", s: 0.5 },
      { id: "cccc", s: 0.9 }
    ]
    sorted = CCE::NumericFormat.sort_by_score_desc(
      items, score: ->(x) { x[:s] }, id: ->(x) { x[:id] }
    )
    assert_equal %w[cccc aaaa bbbb], sorted.map { |x| x[:id] }
  end
end
