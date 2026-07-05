# WHY: The hashing embedder needs a fast, deterministic, language-agnostic hash
#      so that identical tokens map to identical vector buckets in every
#      implementation. FNV-1a-64 is that hash (SPEC §5.1).
# WHAT: A pure FNV-1a 64-bit hash over the raw bytes of a token.
# RESPONSIBILITIES:
#   - Compute wrapping 64-bit FNV-1a exactly (offset basis + prime from spec).
#   - Own nothing else — no bucketing, no signs (that lives in the embedder).

module CCE
  module Hashing
    OFFSET_BASIS = 0xcbf29ce484222325
    PRIME        = 0x00000100000001b3
    MASK64       = 0xFFFFFFFFFFFFFFFF

    module_function

    # @param bytes [String] token whose raw bytes are hashed
    # @return [Integer] unsigned 64-bit FNV-1a hash
    def fnv1a64(bytes)
      hash = OFFSET_BASIS
      bytes.each_byte do |b|
        hash ^= b
        hash = (hash * PRIME) & MASK64
      end
      hash
    end
  end
end
