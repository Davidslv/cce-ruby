# WHY: The indexer must only see real, text, in-scope source files. Walking the
#      tree with the right ignore rules keeps the corpus clean and indexing fast
#      (SPEC §7.1).
# WHAT: A recursive file walker yielding in-scope files with their relative paths.
# RESPONSIBILITIES:
#   - Skip .git/.cce/node_modules/.venv/venv/__pycache__/dist/build and any dotdir.
#   - Skip files > 2 MB and files that are not valid UTF-8.
#   - Skip sensitive files entirely (never read them) unless secrets are allowed,
#     counting them under a separate `sensitive_skipped` tally (SPEC-V2.1 §2).
#   - Return relative paths normalised to "/" separators, sorted deterministically.
#   - Deliberately NOT own chunking, redaction, or persistence.

require "find"
require_relative "config"
require_relative "sensitive"

module CCE
  module Walker
    module_function

    # @param root [String] directory to index
    # @return [Array<Hash>] each { path: absolute, rel: "a/b.py", content: String }
    def walk(root)
      root = File.expand_path(root)
      results = []
      each_file(root) do |abs|
        rel = relative(root, abs)
        content = read_text(abs)
        next unless content

        results << { path: abs, rel: rel, content: content }
      end
      results.sort_by { |f| f[:rel] }
    end

    # Like `walk` but also reports how many candidate files were skipped for
    # being oversized or non-UTF-8 (`skipped`) and, separately, how many were
    # skipped for being sensitive by name (`sensitive_skipped`, SPEC-V2.1 §2).
    # A sensitive file is never read. Directory exclusions are not counted.
    # @param allow_secrets [Boolean] when true, Layer 1 is disabled (read them all)
    # @return [Hash] { files: Array<Hash>, skipped: Integer, sensitive_skipped: Integer }
    def collect(root, allow_secrets: false)
      root = File.expand_path(root)
      files = []
      skipped = 0
      sensitive_skipped = 0
      each_file(root) do |abs|
        if !allow_secrets && Sensitive.sensitive?(File.basename(abs))
          sensitive_skipped += 1
          next
        end
        content = read_text(abs)
        if content.nil?
          skipped += 1
          next
        end
        files << { path: abs, rel: relative(root, abs), content: content }
      end
      { files: files.sort_by { |f| f[:rel] }, skipped: skipped, sensitive_skipped: sensitive_skipped }
    end

    def each_file(root)
      Dir.each_child(root) do |name|
        abs = File.join(root, name)
        if File.directory?(abs)
          next if skip_dir?(name)

          each_file(abs) { |f| yield f }
        elsif File.file?(abs)
          yield abs
        end
      end
    rescue SystemCallError
      # Unreadable directory: skip silently.
    end

    def skip_dir?(name)
      return true if name.start_with?(".") # any dotdir (.git, .cce, .venv, ...)

      Config::IGNORED_DIRS.include?(name) || name == "venv"
    end

    def relative(root, abs)
      abs.delete_prefix(root + File::SEPARATOR).tr(File::SEPARATOR, "/")
    end

    # Read a file only if it is <= size limit and valid UTF-8; else nil.
    def read_text(abs)
      return nil if File.size(abs) > Config::MAX_FILE_BYTES

      bytes = File.binread(abs)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return nil unless text.valid_encoding?

      text
    rescue SystemCallError
      nil
    end
  end
end
