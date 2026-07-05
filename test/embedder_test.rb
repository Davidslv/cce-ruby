# WHY: The hashing embedder and cosine are the deterministic heart of retrieval;
#      published FNV-1a vectors and the cosine anchor must reproduce exactly.
# WHAT: Pins SPEC §5.1 (FNV-1a-64 anchors, embed determinism) and §5.2 (cosine).
# RESPONSIBILITIES: Guard hashing, embedding shape/normalisation, and cosine.

require_relative "test_helper"

class EmbedderTest < Minitest::Test
  include TestSupport

  def test_fnv1a64_empty
    assert_equal 0xcbf29ce484222325, CCE::Hashing.fnv1a64("")
  end

  def test_fnv1a64_a
    assert_equal 0xaf63dc4c8601ec8c, CCE::Hashing.fnv1a64("a")
  end

  def test_fnv1a64_foobar
    assert_equal 0x85944171f73967e8, CCE::Hashing.fnv1a64("foobar")
  end

  def test_embed_dimension_and_norm
    v = CCE::HashEmbedder.new.embed("hash the password")
    assert_equal 256, v.length
    norm = Math.sqrt(v.sum { |x| x * x })
    assert_in_delta 1.0, norm, 1e-9
  end

  def test_embed_empty_is_all_zero
    v = CCE::HashEmbedder.new.embed("")
    assert_equal 256, v.length
    assert(v.all? { |x| x == 0.0 })
  end

  def test_embed_is_deterministic
    e = CCE::HashEmbedder.new
    assert_equal e.embed("process payment amount"), e.embed("process payment amount")
  end

  def test_cosine_anchor
    a = Array.new(256, 0.0)
    a[0] = 0.6
    a[1] = 0.8
    b = Array.new(256, 0.0)
    b[0] = 1.0
    assert_in_delta 0.6, CCE::Embedder.cosine(a, b), 1e-12
  end

  def test_cosine_of_identical_normalized_is_one
    v = CCE::HashEmbedder.new.embed("session manager create")
    assert_in_delta 1.0, CCE::Embedder.cosine(v, v), 1e-9
  end
end
