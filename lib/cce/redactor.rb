# WHY: Even files that are safe to index can carry an inline secret — an AWS key
#      in a config, a token in a comment. Layer 2 scrubs high-confidence secrets
#      out of content BEFORE it is chunked, embedded, or stored, so the local
#      store never holds them (SPEC-V2.1 §1, §2 Layer 2).
# WHAT: A deterministic string→string redactor applying the exact §1 pattern
#       table (specific patterns 1-9, then the generic key=value pattern 10).
# RESPONSIBILITIES:
#   - Replace each matched secret VALUE with `[REDACTED:<LABEL>]`, not the
#     surrounding text.
#   - Apply the pattern-10 placeholder guards so docs/examples survive.
#   - Never re-redact an already-redacted marker (specific label wins).
#   - Deliberately NOT decide which files to read (that is Layer 1 / Sensitive).

module CCE
  module Redactor
    # §1 patterns 1-9, in order (specific → less specific). Each entry is
    # [regexp, label]; the whole match is the secret value to replace.
    SPECIFIC = [
      [/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----/, "PRIVATE_KEY"],
      [/sk-ant-[A-Za-z0-9_-]{20,}/, "ANTHROPIC_KEY"],
      [/sk-[A-Za-z0-9]{32,}/, "OPENAI_KEY"],
      [/sk_live_[A-Za-z0-9]{16,}/, "STRIPE_KEY"],
      [/gh[pousr]_[A-Za-z0-9]{36,}/, "GITHUB_TOKEN"],
      [/xox[baprs]-[A-Za-z0-9-]{10,}/, "SLACK_TOKEN"],
      [/AKIA[0-9A-Z]{16}/, "AWS_ACCESS_KEY"],
      [/AIza[0-9A-Za-z_-]{35}/, "GOOGLE_API_KEY"],
      [/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, "JWT"]
    ].freeze

    # §1 pattern 10: a secret-ish key, an `=`/`:` operator, an optional quote, and
    # a value. Group 1 = key+operator+optional-quote (kept), group 2 = the value.
    KEY = /(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|secret[_-]?key|auth[_-]?token|private[_-]?key)/i
    ASSIGNMENT = /(#{KEY}\s*[:=]\s*["']?)([^\s"']+)/i

    # §1 placeholder guards (pattern 10 only): lowercased value prefixes that mark
    # a non-secret example/placeholder.
    GUARD_PREFIXES = %w[your my- the- example changeme placeholder dummy test sample xxx].freeze
    GUARD_LITERALS = %w[null nil none true false].freeze

    module_function

    # Redact every secret in `content`. Deterministic and idempotent.
    # @param content [String]
    # @return [String] a new string with secret values replaced
    def redact(content)
      text = content.to_s
      SPECIFIC.each do |pattern, label|
        text = text.gsub(pattern, "[REDACTED:#{label}]")
      end
      redact_assignments(text)
    end

    def redact_assignments(text)
      text.gsub(ASSIGNMENT) do
        prefix = Regexp.last_match(1)
        value = Regexp.last_match(2)
        if redactable_value?(value)
          "#{prefix}[REDACTED:SECRET]"
        else
          Regexp.last_match(0)
        end
      end
    end

    # A pattern-10 value is redacted only if it is long enough AND not a guarded
    # placeholder AND not something a specific pattern already redacted.
    def redactable_value?(value)
      return false if value.length < 8
      return false if value.start_with?("[REDACTED:")

      !placeholder?(value)
    end

    # True when the value is a documentation placeholder, an interpolation, a
    # literal, or a single repeated character (§1 pattern-10 guards).
    def placeholder?(value)
      lower = value.downcase
      return true if GUARD_PREFIXES.any? { |p| lower.start_with?(p) }
      return true if GUARD_LITERALS.include?(lower)
      return true if interpolation?(value)
      return true if value.chars.uniq.length == 1

      false
    end

    def interpolation?(value)
      value.match?(/\A<.*>\z/) ||
        value.match?(/\A\$\{.*\}\z/) ||
        value.match?(/\A\{\{.*\}\}\z/)
    end
  end
end
