# WHY: BM25 is half of hybrid retrieval; its exact Lucene-form scoring is pinned
#      by a worked anchor in the spec and must reproduce to ±1e-4 (SPEC §6.3).
# WHAT: Pins the BM25 worked example and candidate selection behaviour.
# RESPONSIBILITIES: Guard idf, scoring, zero-score exclusion, ranking.

require_relative "test_helper"

class KeywordStoreTest < Minitest::Test
  # Build tiny docs matching the spec's worked anchor.
  def build
    docs = [
      doc("d1", "user login user"),
      doc("d2", "payment process")
    ]
    CCE::KeywordStore.new(docs)
  end

  def doc(id, content)
    { chunk_id: id, content: content }
  end

  def test_worked_anchor_scores
    ks = build
    scores = ks.scores(%w[user])
    assert_in_delta 0.902273, scores["d1"], 1e-4
    refute scores.key?("d2"), "documents scoring 0 are excluded"
  end

  def test_avgdl_and_stats
    ks = build
    assert_in_delta 2.5, ks.avgdl, 1e-12
    assert_equal 2, ks.doc_count
  end

  def test_candidates_ranked_and_capped
    ks = build
    cands = ks.candidates(%w[user process], limit: 5)
    ids = cands.map { |c| c[:chunk_id] }
    assert_equal %w[d1 d2].sort, ids.sort
    # d1 matches "user" (idf>0) ; d2 matches "process"
    frank = ks.ranks(%w[user process], limit: 5)
    assert frank.key?("d1")
  end

  def test_no_query_terms_returns_empty
    ks = build
    assert_empty ks.candidates(%w[zzz nonexistent], limit: 5)
  end
end
