# WHY: The CLI is how users (and agents) drive sync; it must dispatch each
#      subcommand, print friendly output, and turn every failure into a clear
#      non-zero message without ever crashing (SPEC-SYNC §5, §10.5).
# WHAT: End-to-end CLI tests for `cce sync ...` over a local bare cache repo.

require_relative "test_helper"
require "stringio"

class SyncCliTest < Minitest::Test
  include TestSupport

  def run_cli(argv, home:)
    out = StringIO.new
    err = StringIO.new
    old = ENV["HOME"]
    ENV["HOME"] = home
    code = CCE::CLI.new(out, err).run(argv)
    [code, out.string, err.string]
  ensure
    ENV["HOME"] = old
  end

  # A configured source repo + bare cache; yields (root, sha, home).
  def with_cli_project
    with_tmpdir do |dir|
      home = File.join(dir, "home"); FileUtils.mkdir_p(home)
      cache = bare_repo(File.join(dir, "cache.git"))
      root = File.join(dir, "A")
      sha = init_source_repo(root, SYNC_SAMPLE)
      run_cli(["sync", "init", "--remote", "file://#{cache}", "--no-lfs",
               "--repo-id", "github.com__acme__demo", root], home: home)
      yield root, sha, home, cache
    end
  end

  def test_help_lists_sync
    code, out, _ = run_cli(["help"], home: Dir.mktmpdir)
    assert_equal 0, code
    assert_match(/cce sync init/, out)
    assert_match(/cce sync push/, out)
  end

  def test_full_cli_flow
    with_cli_project do |root, sha, home, _cache|
      code, out, err = run_cli(["sync", "push", root], home: home)
      assert_equal 0, code, err
      assert_match(/pushed github.com__acme__demo@#{sha[0, 12]}/, out)
      assert_match(/checksum: [0-9a-f]{64}/, out)

      code, out, = run_cli(["sync", "status", root], home: home)
      assert_equal 0, code
      assert_match(/Tree matches:  yes/, out)

      code, out, err = run_cli(["sync", "verify", root], home: home)
      assert_equal 0, code, err
      assert_match(/verify OK/, out)
    end
  end

  def test_cli_pull_into_fresh_dir
    with_cli_project do |root, sha, home, cache|
      run_cli(["sync", "push", root], home: home)
      Dir.mktmpdir do |bdir|
        broot = File.join(bdir, "B"); FileUtils.mkdir_p(broot)
        SYNC_SAMPLE.each { |rel, c| File.write(File.join(broot, rel), c) }
        run_cli(["sync", "init", "--remote", "file://#{cache}", "--no-lfs",
                 "--repo-id", "github.com__acme__demo", broot], home: home)
        code, out, err = run_cli(["sync", "pull", "--commit", sha, broot], home: home)
        assert_equal 0, code, err
        assert_match(/Installed cache/, out)
        assert File.exist?(File.join(broot, ".cce", "index.db"))
      end
    end
  end

  def test_status_not_configured
    with_tmpdir do |dir|
      code, out, = run_cli(["sync", "status", dir], home: dir)
      assert_equal 0, code
      assert_match(/not configured/, out)
    end
  end

  def test_unknown_subcommand
    code, _out, err = run_cli(["sync", "bogus"], home: Dir.mktmpdir)
    assert_equal 2, code
    assert_match(/init \| push \| pull \| status \| verify/, err)
  end

  def test_init_requires_remote
    with_tmpdir do |dir|
      code, _out, err = run_cli(["sync", "init", dir], home: dir)
      assert_equal 2, code
      assert_match(/requires --remote/, err)
    end
  end

  def test_verify_fail_exit_code
    with_cli_project do |root, sha, home, cache|
      run_cli(["sync", "push", root], home: home)
      # Poison the manifest's recorded checksum so the honest rebuild disagrees.
      remote = git_remote_for(cache, File.dirname(root))
      key = CCE::Sync::ContentAddress.key(repo_id: "github.com__acme__demo", sha: sha)
      bytes = remote.get(key)
      remote.put(key, bytes.sub(/"checksum":"[0-9a-f]{64}"/, %("checksum":"#{'0' * 64}")))
      code, _out, err = run_cli(["sync", "verify", root], home: home)
      assert_equal 1, code
      assert_match(/verify FAILED/, err)
    end
  end

  def test_pull_cache_miss_exit_code
    with_cli_project do |root, _sha, home, _cache|
      code, _out, err = run_cli(["sync", "pull", root], home: home)
      assert_equal 1, code
      assert_match(/cache miss/, err)
    end
  end
end
