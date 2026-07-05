# WHY: The tokenizer is shared by the embedder, BM25, and keyword matching; its
#      exact behaviour is load-bearing for cross-implementation equivalence.
# WHAT: Pins the SPEC §4.1 anchor tests for tokenization.
# RESPONSIBILITIES: Guard byte-run tokenization and ASCII lowercasing rules.

require_relative "test_helper"

class TokenizerTest < Minitest::Test
  include TestSupport

  def test_anchor_hash_password
    assert_equal %w[hashpassword user_id], CCE::Tokenizer.tokenize("hashPassword(user_id)")
  end

  def test_anchor_sql
    assert_equal %w[select from users], CCE::Tokenizer.tokenize("SELECT * FROM users;")
  end

  def test_empty
    assert_equal [], CCE::Tokenizer.tokenize("")
  end

  def test_camelcase_not_split
    assert_equal %w[getuserbyid], CCE::Tokenizer.tokenize("getUserById")
  end

  def test_non_ascii_is_separator
    # Each non-ASCII byte is a separator, so multi-byte codepoints split runs.
    assert_equal %w[caf na ve], CCE::Tokenizer.tokenize("café naïve")
  end

  def test_digits_and_underscore_are_word_bytes
    assert_equal %w[abc_123], CCE::Tokenizer.tokenize("abc_123")
  end

  def test_no_dedup_preserves_order
    assert_equal %w[user login user], CCE::Tokenizer.tokenize("user login user")
  end
end
