# WHY: A single tokenizer feeds the embedder, BM25 scoring, and keyword
#      matching. If those three disagreed on what a "token" is, retrieval would
#      be internally inconsistent and cross-implementation equivalence (the
#      conformance gate) would be impossible.
# WHAT: The exact byte-oriented tokenizer from SPEC §4.1.
# RESPONSIBILITIES:
#   - Split raw UTF-8 bytes into maximal [A-Za-z0-9_] runs (all else separators).
#   - Lowercase only ASCII A–Z bytes; leave every other byte untouched.
#   - Preserve left-to-right order and NOT deduplicate.

module CCE
  module Tokenizer
    module_function

    # A byte is a "word byte" iff it is an ASCII letter, digit, or underscore.
    WORD_BYTE = Array.new(256, false)
    ("A".ord.."Z".ord).each { |b| WORD_BYTE[b] = true }
    ("a".ord.."z".ord).each { |b| WORD_BYTE[b] = true }
    ("0".ord.."9".ord).each { |b| WORD_BYTE[b] = true }
    WORD_BYTE["_".ord] = true
    WORD_BYTE.freeze

    UPPER_A = "A".ord
    UPPER_Z = "Z".ord
    ASCII_SHIFT = "a".ord - "A".ord

    # @param text [String] arbitrary text (any encoding; treated as raw bytes)
    # @return [Array<String>] lowercased tokens in order
    def tokenize(text)
      return [] if text.nil? || text.empty?

      tokens = []
      current = nil
      text.each_byte do |b|
        if WORD_BYTE[b]
          b += ASCII_SHIFT if b >= UPPER_A && b <= UPPER_Z # ASCII lowercase
          if current
            current << b
          else
            current = [b]
          end
        elsif current
          tokens << current.pack("C*").force_encoding(Encoding::UTF_8)
          current = nil
        end
      end
      tokens << current.pack("C*").force_encoding(Encoding::UTF_8) if current
      tokens
    end
  end
end
