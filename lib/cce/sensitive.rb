# WHY: The cheapest, strongest secret protection is to never read a file that is,
#      by its very name, a credential store (SPEC-V2.1 §1, §2 Layer 1). A `.env`,
#      a `.pem`, an `id_rsa` should never enter the corpus at all.
# WHAT: A pure, side-effect-free classifier answering "is this basename too
#       sensitive to index?" from the normative §1 tables and the dotenv rule.
# RESPONSIBILITIES:
#   - Own the §1 sensitive-extension set, exact-basename set, and dotenv rule.
#   - Decide sensitivity from a basename alone, case-insensitively.
#   - Deliberately NOT read files, walk trees, or redact content.

module CCE
  module Sensitive
    # §1 sensitive file extensions (compared without the dot, case-insensitive).
    EXTENSIONS = %w[pem key p12 pfx keystore jks ppk der asc].freeze

    # §1 sensitive exact basenames (whole file name, case-insensitive).
    BASENAMES = %w[
      credentials.json credentials.yml credentials.yaml
      secrets.json secrets.yml secrets.yaml
      .netrc .pgpass .htpasswd .dockercfg kubeconfig
      id_rsa id_dsa id_ecdsa id_ed25519
    ].freeze

    # §1 dotenv rule: `.env` or `.env.*` is sensitive EXCEPT these safe-template
    # suffixes (a template carries no live secret and must be indexed).
    SAFE_ENV_SUFFIXES = %w[.example .sample .template .dist].freeze

    module_function

    # @param basename [String] a file's basename (not a path)
    # @return [Boolean] true if the file must never be read/indexed
    def sensitive?(basename)
      name = basename.to_s
      lower = name.downcase
      return true if BASENAMES.include?(lower)
      return true if sensitive_extension?(lower)

      dotenv_secret?(lower)
    end

    # Final extension (after the last dot) is in the §1 extension set.
    def sensitive_extension?(lower)
      dot = lower.rindex(".")
      return false unless dot && dot < lower.length - 1

      EXTENSIONS.include?(lower[(dot + 1)..])
    end

    # `.env` / `.env.*` minus the safe-template suffixes.
    def dotenv_secret?(lower)
      return false unless lower == ".env" || lower.start_with?(".env.")
      return false if SAFE_ENV_SUFFIXES.any? { |suffix| lower.end_with?(suffix) }

      true
    end
  end
end
