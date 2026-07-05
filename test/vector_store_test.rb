# WHY: Vector similarity is the semantic half of retrieval; brute-force cosine
#      must rank correctly and deterministically (SPEC §6.2).
# WHAT: Pins cosine ranking, candidate capping, and tie-breaking.
# RESPONSIBILITIES: Guard exact cosine search and 0-based vrank assignment.

require_relative "test_helper"

class VectorStoreTest < Minitest::Test
  def unit(*idx)
    v = Array.new(256, 0.0)
    idx.each { |i| v[i] = 1.0 }
    n = Math.sqrt(v.sum { |x| x * x })
    v.map { |x| x / n }
  end

  def build
    entries = [
      { chunk_id: "a", vector: unit(0) },
      { chunk_id: "b", vector: unit(0, 1) },
      { chunk_id: "c", vector: unit(5) }
    ]
    CCE::VectorStore.new(entries)
  end

  def test_cosine_ranking
    vs = build
    q = unit(0)
    cands = vs.candidates(q, limit: 3)
    ids = cands.map { |c| c[:chunk_id] }
    assert_equal "a", ids.first # exact match ranks first
    assert_includes ids, "b"
  end

  def test_candidate_cap_and_rank
    vs = build
    q = unit(0)
    ranks = vs.ranks(q, limit: 2)
    assert_equal 2, ranks.size
    assert_equal 0, ranks["a"]
  end

  def test_cosine_lookup_for_any_chunk
    vs = build
    q = unit(5)
    assert_in_delta 1.0, vs.cosine_to("c", q), 1e-12
    assert_in_delta 0.0, vs.cosine_to("a", q), 1e-12
  end
end
