# WHY: Layer 2 must strip high-confidence secrets out of indexed content before
#      it is chunked, embedded, or stored (SPEC-V2.1 §1, §2). Both language
#      implementations must redact identical input identically, so every pattern
#      and every placeholder guard is pinned here.
# WHAT: Pins CCE::Redactor.redact across each §1 label and the §1 pattern-10
#       guards, including the exact §3 unit cases.
# RESPONSIBILITIES: Guard the redactor's pattern table, ordering, and guards.
#
# NOTE: real-format secret inputs come from SecretLiterals (test_helper.rb), which
#       assembles them from split fragments at runtime, so this committed source
#       holds no contiguous secret-shaped literal.

require_relative "test_helper"

class RedactorTest < Minitest::Test
  def redact(s) = CCE::Redactor.redact(s)

  # ---- specific patterns (1-9) --------------------------------------------

  def test_private_key_block
    input = [SecretLiterals::RSA_BEGIN,
             "MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF0qs",
             SecretLiterals::RSA_END, ""].join("\n")
    out = redact(input)
    assert_includes out, "[REDACTED:PRIVATE_KEY]"
    refute_includes out, "MIIEpAIBAAKCAQEA"
    refute_includes out, "BEGIN RSA PRIVATE " + "KEY"
  end

  def test_anthropic_key
    assert_equal "x=[REDACTED:ANTHROPIC_KEY]", redact("x=" + SecretLiterals::ANTHROPIC)
  end

  def test_openai_key
    out = redact("OPENAI=" + SecretLiterals::OPENAI)
    assert_includes out, "[REDACTED:OPENAI_KEY]"
    refute_includes out, "sk-" + "abcdefghijkl"
  end

  def test_stripe_key
    assert_equal "[REDACTED:STRIPE_KEY]", redact(SecretLiterals::STRIPE)
  end

  def test_github_token
    assert_equal "[REDACTED:GITHUB_TOKEN]", redact(SecretLiterals::GITHUB)
  end

  def test_slack_token
    assert_includes redact(SecretLiterals::SLACK), "[REDACTED:SLACK_TOKEN]"
  end

  def test_aws_access_key
    assert_equal "[REDACTED:AWS_ACCESS_KEY]", redact(SecretLiterals::AWS)
  end

  def test_google_api_key
    assert_includes redact(SecretLiterals::GOOGLE), "[REDACTED:GOOGLE_API_KEY]"
  end

  def test_jwt
    assert_equal "[REDACTED:JWT]", redact(SecretLiterals::JWT)
  end

  # ---- generic assignment (pattern 10) ------------------------------------

  def test_secret_assignment_bare
    assert_equal "password=[REDACTED:SECRET]", redact("password=hunter2secret")
  end

  def test_secret_assignment_quoted_and_colon
    assert_equal 'api_key: "[REDACTED:SECRET]"',
                 redact('api_key: "s3cr3tValue123"')
  end

  def test_secret_assignment_various_keys
    assert_includes redact('auth_token = "abcd1234efgh"'), "[REDACTED:SECRET]"
    assert_includes redact('access-key: longenoughvalue'), "[REDACTED:SECRET]"
  end

  # ---- placeholder guards (pattern 10 negatives) --------------------------

  def test_placeholder_guard_your_prefix
    assert_equal 'key = "your-api-key"', redact('key = "your-api-key"')
  end

  def test_placeholder_guard_prefixes
    ['password=changeme123', 'token=placeholder_value', 'secret=example_secret',
     'password=dummy_value', 'api_key=test_key_value', 'token=sample_token'].each do |s|
      assert_equal s, redact(s), "expected #{s} to be guarded"
    end
  end

  def test_placeholder_guard_interpolation
    ['password=${DB_PASSWORD}', 'token={{token_here}}', 'secret=<your-secret>'].each do |s|
      assert_equal s, redact(s), "expected interpolation #{s} unchanged"
    end
  end

  def test_placeholder_guard_literals
    %w[null nil none true false].each do |v|
      s = "password=#{v}"
      assert_equal s, redact(s)
    end
  end

  def test_placeholder_guard_too_short
    # Value under 8 chars is not redacted.
    assert_equal "password=short", redact("password=short")
  end

  def test_placeholder_guard_single_repeated_char
    assert_equal "password=xxxxxxxx", redact("password=xxxxxxxx")
  end

  def test_non_secret_key_untouched
    assert_equal "name=johndoe123", redact("name=johndoe123")
  end

  # ---- ordering / no double-redaction -------------------------------------

  def test_specific_pattern_wins_over_generic
    # A github token assigned to a secret-ish key keeps its specific label,
    # it is NOT re-redacted to the generic SECRET label.
    assert_equal 'token = "[REDACTED:GITHUB_TOKEN]"',
                 redact('token = "' + SecretLiterals::GITHUB + '"')
  end

  def test_idempotent
    input = 'password=hunter2secret'
    once = redact(input)
    assert_equal once, redact(once)
  end

  def test_clean_content_unchanged
    src = "def add(a, b)\n  a + b\nend\n"
    assert_equal src, redact(src)
  end
end
