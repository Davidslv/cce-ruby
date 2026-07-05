# WHY: The whole point of the pack architecture is that the core engine holds
#      zero language-specific knowledge (SPEC-V2 §1). If a language name or an
#      extension literal leaks back into the core chunker/importer, that
#      invariant is silently broken — so we guard it with a grep-style test.
# WHAT: Asserts the core chunker and importer files name no language and no
#       file-extension literal.
# RESPONSIBILITIES: Keep language knowledge confined to lib/cce/packs/*.

require_relative "test_helper"

class CoreLanguageGuardTest < Minitest::Test
  LIB = File.expand_path("../lib/cce", __dir__)

  # The files that must stay language-blind.
  CORE_FILES = %w[chunker.rb indexer.rb pack_registry.rb].freeze

  # Language names no core file may mention (as whole words).
  LANGUAGE_NAMES = %w[python javascript typescript rust golang].freeze

  def read(file) = File.read(File.join(LIB, file))

  def test_core_files_name_no_language
    CORE_FILES.each do |file|
      body = read(file)
      LANGUAGE_NAMES.each do |lang|
        refute_match(/\b#{Regexp.escape(lang)}\b/i, body,
                     "#{file} must not mention the language #{lang.inspect}")
      end
    end
  end

  def test_core_files_contain_no_extension_literals
    CORE_FILES.each do |file|
      body = read(file)
      # e.g. ".py", ".rb", ".tsx" as a quoted literal.
      refute_match(/["']\.[a-z]{1,4}["']/, body,
                   "#{file} must not hard-code a file-extension literal")
    end
  end

  def test_core_files_reference_the_registry_not_a_language_table
    body = read("chunker.rb")
    assert_includes body, "registry"
    refute_includes body, "LANGUAGE_BY_EXT"
  end
end
