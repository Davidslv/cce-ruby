# WHY: Layer 1 must decide, from a basename alone, whether a file is too
#      sensitive to ever read (SPEC-V2.1 §1, §2). Getting the extension /
#      exact-basename / dotenv rules right is the whole guarantee.
# WHAT: Pins CCE::Sensitive.sensitive? across every §1 category and its guards.
# RESPONSIBILITIES: Guard the sensitive-file classifier (extensions, basenames,
#   the dotenv rule and its safe-template exceptions), case-insensitively.

require_relative "test_helper"

class SensitiveTest < Minitest::Test
  def sensitive?(name) = CCE::Sensitive.sensitive?(name)

  def test_sensitive_extensions
    %w[id_rsa.pem server.key cert.p12 bundle.pfx store.keystore app.jks
       key.ppk sig.der pubring.asc].each do |name|
      assert sensitive?(name), "expected #{name} sensitive by extension"
    end
  end

  def test_sensitive_extensions_case_insensitive
    assert sensitive?("SERVER.KEY")
    assert sensitive?("Cert.PEM")
  end

  def test_non_sensitive_extensions
    %w[main.rb app.py notes.md keyboard.ts monkey.go].each do |name|
      refute sensitive?(name), "expected #{name} NOT sensitive"
    end
  end

  def test_sensitive_exact_basenames
    %w[credentials.json credentials.yml credentials.yaml
       secrets.json secrets.yml secrets.yaml
       .netrc .pgpass .htpasswd .dockercfg kubeconfig
       id_rsa id_dsa id_ecdsa id_ed25519].each do |name|
      assert sensitive?(name), "expected #{name} sensitive by basename"
    end
  end

  def test_sensitive_exact_basenames_case_insensitive
    assert sensitive?("Credentials.JSON")
    assert sensitive?("KUBECONFIG")
  end

  def test_similar_but_safe_basenames
    # A different stem or extension must not trip the exact-basename rule.
    refute sensitive?("credentials.rb")
    refute sensitive?("my_secrets.json")
    refute sensitive?("secrets_helper.rb")
    refute sensitive?("id_rsa_helper.rb")
  end

  def test_dotenv_is_sensitive
    assert sensitive?(".env")
    assert sensitive?(".env.local")
    assert sensitive?(".env.production")
    assert sensitive?(".ENV")
    assert sensitive?(".Env.Local")
  end

  def test_dotenv_safe_templates_are_not_sensitive
    %w[.env.example .env.sample .env.template .env.dist
       .env.local.example .env.EXAMPLE].each do |name|
      refute sensitive?(name), "expected #{name} to be a safe template"
    end
  end

  def test_plain_env_named_files_are_not_sensitive
    refute sensitive?("environment.rb")
    refute sensitive?("env.rb")
  end
end
