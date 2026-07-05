# WHY: The two protection layers only matter if they compose correctly on a real
#      tree: sensitive files never read, secrets redacted before they hit the
#      store, and `--allow-secrets` turning both off (SPEC-V2.1 §2, §3).
# WHAT: Generates the SPEC-V2.1 §3 secrets corpus into a temp dir at runtime and
#       drives it through the walker, the indexer, and the `index` CLI, asserting
#       the exact §3 outcomes.
# RESPONSIBILITIES: Guard Layer-1 skip tallies, Layer-2 redaction of stored
#   content, and the `--allow-secrets` bypass end to end.
#
# NOTE: the secret-bearing fixture files (.env, id_rsa, config.rb) are written by
#       write_secrets_fixture (test_helper.rb) into a throwaway temp dir, so no
#       repository file contains a contiguous secret. Their contents are
#       real-format at runtime (assembled from SecretLiterals fragments).

require_relative "test_helper"
require "stringio"

class SecretsFixtureTest < Minitest::Test
  include TestSupport

  # Build the §3 secrets fixture under `<tmp>/src` and yield [src_dir, tmp_dir].
  def with_secrets_dir
    with_tmpdir do |tmp|
      src = File.join(tmp, "src")
      FileUtils.mkdir_p(src)
      write_secrets_fixture(src)
      yield src, tmp
    end
  end

  # ---- Layer 1: walker ------------------------------------------------------

  def test_walker_skips_sensitive_files_by_default
    with_secrets_dir do |src, _tmp|
      collected = CCE::Walker.collect(src)
      rels = collected[:files].map { |f| f[:rel] }.sort
      assert_equal %w[.env.example config.rb], rels
      assert_equal 2, collected[:sensitive_skipped] # .env + id_rsa
    end
  end

  def test_walker_reads_sensitive_files_when_allowed
    with_secrets_dir do |src, _tmp|
      collected = CCE::Walker.collect(src, allow_secrets: true)
      rels = collected[:files].map { |f| f[:rel] }.sort
      assert_equal %w[.env .env.example config.rb id_rsa], rels
      assert_equal 0, collected[:sensitive_skipped]
    end
  end

  # ---- Layer 2 + Layer 1 end-to-end via the indexer -------------------------

  def stored_chunks(src, tmp, **opts)
    store_path = File.join(tmp, ".cce", "index.db")
    summary = CCE::Indexer.index(src, store_path: store_path, **opts)
    store = CCE::Store.open(store_path)
    begin
      [summary, store.chunks]
    ensure
      store.close
    end
  end

  def test_default_run_skips_and_redacts
    with_secrets_dir do |src, tmp|
      summary, chunks = stored_chunks(src, tmp)

      files = chunks.map(&:file_path).uniq.sort
      assert_equal %w[.env.example config.rb], files
      assert_equal 2, summary[:sensitive_skipped]

      # No chunk/row derives from a skipped sensitive file.
      refute_includes files, ".env"
      refute_includes files, "id_rsa"

      config = chunks.select { |c| c.file_path == "config.rb" }.map(&:content).join("\n")
      assert_includes config, "[REDACTED:AWS_ACCESS_KEY]"
      assert_includes config, "[REDACTED:STRIPE_KEY]"
      refute_includes config, SecretLiterals::AWS
      refute_includes config, SecretLiterals::STRIPE
      # Placeholder guard leaves the doc example intact.
      assert_includes config, "your-api-key-here"
    end
  end

  def test_env_example_is_indexed_as_module_fallback
    with_secrets_dir do |src, tmp|
      _summary, chunks = stored_chunks(src, tmp)
      env = chunks.select { |c| c.file_path == ".env.example" }
      assert_equal 1, env.length
      assert_equal "module", env.first.chunk_type
    end
  end

  def test_allow_secrets_bypasses_both_layers
    with_secrets_dir do |src, tmp|
      summary, chunks = stored_chunks(src, tmp, allow_secrets: true)

      files = chunks.map(&:file_path).uniq.sort
      assert_equal %w[.env .env.example config.rb id_rsa], files
      assert_equal 0, summary[:sensitive_skipped]

      # config.rb is stored verbatim — no redaction.
      config = chunks.select { |c| c.file_path == "config.rb" }.map(&:content).join("\n")
      assert_includes config, SecretLiterals::AWS
      assert_includes config, SecretLiterals::STRIPE
      refute_includes config, "[REDACTED"
    end
  end

  # ---- CLI reporting --------------------------------------------------------

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    code = CCE::CLI.run(argv, out: out, err: err)
    [code, out.string, err.string]
  end

  def test_cli_index_reports_sensitive_skipped
    with_secrets_dir do |src, tmp|
      store = File.join(tmp, "index.db")
      code, out, _err = run_cli(["index", src, "--store", store, "--no-metrics"])
      assert_equal 0, code
      assert_match(/sensitive/i, out)
      assert_match(/2/, out)
    end
  end

  def test_cli_allow_secrets_prints_warning
    with_secrets_dir do |src, tmp|
      store = File.join(tmp, "index.db")
      code, _out, err = run_cli(
        ["index", src, "--store", store, "--no-metrics", "--allow-secrets"]
      )
      assert_equal 0, code
      assert_match(/allow-secrets|protection.*disabled/i, err)
    end
  end
end
