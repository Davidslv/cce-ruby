# WHY: The engine must resolve any file to its language behaviour without ever
#      naming a language itself (SPEC-V2 §1.1). The registry is that single
#      indirection: packs register here, and the chunker/importer ask it "what
#      handles this path?" — so adding a language is add-a-pack, no core edits.
# WHAT: An ordered collection of LanguagePacks with extension-based resolution.
# RESPONSIBILITIES:
#   - Register packs, rejecting any extension already claimed (Layer-1 invariant).
#   - Resolve a file path to its pack by lowercased extension.
#   - Expose all packs for validation and `cce packs`.
#   - Deliberately hold NO language-specific knowledge of its own.

module CCE
  class PackRegistry
    class DuplicateExtension < StandardError; end

    def initialize
      @packs = []
      @by_ext = {}
    end

    # Register a pack. Raises if any of its extensions is already claimed.
    # @param pack the LanguagePack instance
    # @return [self]
    def register(pack)
      pack.extensions.each do |ext|
        key = ext.downcase
        if @by_ext.key?(key)
          owner = @by_ext[key].name
          raise DuplicateExtension,
                %([pack:#{pack.name}] extension "#{ext}" already claimed by pack ) +
                %("#{owner}"; each extension maps to exactly one pack.)
        end
      end
      pack.extensions.each { |ext| @by_ext[ext.downcase] = pack }
      @packs << pack
      self
    end

    # @param path [String] a file path
    # @return the pack that claims its extension, or nil
    def pack_for(path)
      @by_ext[File.extname(path.to_s).downcase]
    end

    # @return [Array] all registered packs, in registration order
    def all
      @packs.dup
    end

    def empty?
      @packs.empty?
    end
  end
end
