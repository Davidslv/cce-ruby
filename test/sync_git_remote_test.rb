# WHY: GitRemote is the default backend: it must put/get by content address,
#      survive a concurrent-push ref race with fetch-rebase-retry, seed an empty
#      remote, and (optionally) route blobs through git-LFS (SPEC-SYNC §4, §11).
#      Core tests use PLAIN git so they never require the git-lfs binary; the LFS
#      path is a smoke test that SKIPS when git-lfs is absent.
# WHAT: Integration tests for CCE::Sync::GitRemote over a local bare repo.

require_relative "test_helper"

class SyncGitRemoteTest < Minitest::Test
  include TestSupport

  KEY = "hash/2.3/github.com__acme__demo/#{'a' * 40}.cce"

  def test_put_then_get_round_trips_and_seeds_empty_remote
    with_tmpdir do |dir|
      bare = bare_repo(File.join(dir, "cache.git"))
      r = git_remote_for(bare, dir)
      assert_equal :pushed, r.put(KEY, "hello-artifact")
      # a fresh clone (second working dir) can read it back
      r2 = git_remote_for(bare, dir)
      assert_equal "hello-artifact", r2.get(KEY)
      assert r2.has(KEY)
      refute r2.has("hash/2.3/github.com__acme__demo/#{'b' * 40}.cce")
    end
  end

  def test_put_unchanged_when_identical
    with_tmpdir do |dir|
      bare = bare_repo(File.join(dir, "cache.git"))
      r = git_remote_for(bare, dir)
      r.put(KEY, "same")
      assert_equal :unchanged, r.put(KEY, "same")
    end
  end

  def test_list_and_latest
    with_tmpdir do |dir|
      bare = bare_repo(File.join(dir, "cache.git"))
      r = git_remote_for(bare, dir)
      prefix = "hash/2.3/github.com__acme__demo"
      r.put("#{prefix}/#{'a' * 40}.cce", "one")
      sleep 1.1 # ensure a strictly newer commit timestamp for `latest`
      r.put("#{prefix}/#{'b' * 40}.cce", "two")
      assert_equal ["a" * 40, "b" * 40].sort, r.list(prefix).sort
      assert_equal "b" * 40, r.latest(prefix)
      assert_empty r.list("hash/2.3/nope")
      assert_nil r.latest("hash/2.3/nope")
    end
  end

  def test_push_race_retry
    with_tmpdir do |dir|
      bare = bare_repo(File.join(dir, "cache.git"))
      prefix = "hash/2.3/github.com__acme__demo"
      a = git_remote_for(bare, dir)
      b = git_remote_for(bare, dir)
      # Both clone the (empty) remote first, then A pushes, then B pushes a
      # DIFFERENT key: B's push is initially rejected (non-ff) and must
      # fetch-rebase-retry.
      a.ensure_clone!
      b.ensure_clone!
      a.put("#{prefix}/#{'a' * 40}.cce", "A")
      b.put("#{prefix}/#{'b' * 40}.cce", "B")
      reader = git_remote_for(bare, dir)
      assert_equal "A", reader.get("#{prefix}/#{'a' * 40}.cce")
      assert_equal "B", reader.get("#{prefix}/#{'b' * 40}.cce")
    end
  end

  # Smoke test: proves `sync init` wires git-LFS for *.cce. It SKIPS when the
  # git-lfs binary is absent (core tests never need it). We assert LFS is
  # genuinely configured and tracking the artifact — not the transfer mechanics,
  # since git-lfs *can* smudge over a file:// remote (an earlier "get returns a
  # pointer" assumption was wrong and flaked on CI, where git-lfs is installed).
  def test_lfs_smoke_or_skip
    skip "git-lfs not installed" unless CCE::Sync::Git.lfs_available?

    with_tmpdir do |dir|
      bare = bare_repo(File.join(dir, "cache.git"))
      r = CCE::Sync::GitRemote.new(url: "file://#{bare}", clone_dir: File.join(dir, "clone"), lfs: true)
      r.init_lfs!
      r.put(KEY, "lfs-artifact-bytes")

      attrs = File.read(File.join(dir, "clone", ".gitattributes"))
      assert_match(/\*\.cce filter=lfs/, attrs)
      # the clean/smudge round-trip preserves the real bytes in the working tree
      assert_equal "lfs-artifact-bytes", File.binread(File.join(dir, "clone", KEY))
      # git-lfs is genuinely tracking the committed *.cce artifact
      lfs_listed = Dir.chdir(File.join(dir, "clone")) { %x(git lfs ls-files) }
      assert_match(/\.cce/, lfs_listed)
    end
  end

  def test_remote_id_is_stable_and_safe
    id1 = CCE::Sync::GitRemote.remote_id("git@github.com:acme/cache.git")
    id2 = CCE::Sync::GitRemote.remote_id("git@github.com:acme/cache.git")
    assert_equal id1, id2
    refute_equal id1, CCE::Sync::GitRemote.remote_id("git@github.com:acme/other.git")
  end
end
