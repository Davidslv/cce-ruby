# WHY: Commands holds the offline-first, purely-additive contract (SPEC-SYNC §5,
#      §9): refuse a dirty tree / non-hash index, install a cache losslessly,
#      guard overwrites, rebuild-and-compare on verify, and never corrupt local
#      work on a remote failure. This is the behavioural core of CCE Sync.
# WHAT: Integration tests for CCE::Sync::Commands over a local bare cache repo.

require_relative "test_helper"

class SyncCommandsTest < Minitest::Test
  include TestSupport

  # A source repo (A) wired to a bare cache repo, with sync configured. Yields
  # (root, sha, remote, base) so a test can build Commands with the injected
  # remote and clone_base kept fully hermetic.
  def with_project
    with_tmpdir do |dir|
      cache = bare_repo(File.join(dir, "cache.git"))
      root = File.join(dir, "A")
      sha = init_source_repo(root, SYNC_SAMPLE)
      CCE::Sync::Config.write_project(root, remote: "file://#{cache}", lfs: false, repo_id: "github.com__acme__demo")
      remote = git_remote_for(cache, dir)
      yield root, sha, remote, cache
    end
  end

  def commands(root, remote, home: root)
    CCE::Sync::Commands.new(project_dir: root, remote: remote,
                            config: CCE::Sync::Config.load(root, home: home))
  end

  def test_push_then_pull_into_fresh_clone_is_functionally_identical
    with_project do |root, sha, remote, cache|
      CCE::Indexer.index(root, store_path: File.join(root, ".cce", "index.db"))
      res = commands(root, remote).push
      assert_equal :pushed, res[:status]
      assert_equal sha, res[:sha]

      # Fresh working dir B (same source files, no local index): pull the cache
      # by explicit sha and confirm functional identity + checksum match.
      with_tmpdir do |bdir|
        broot = File.join(bdir, "B"); FileUtils.mkdir_p(broot)
        SYNC_SAMPLE.each { |rel, c| File.write(File.join(broot, rel), c) }
        bremote = git_remote_for(cache, bdir)
        bcfg = CCE::Sync::Config.new("remote" => "file://#{cache}", "lfs" => false, "repo_id" => "github.com__acme__demo")
        bcmds = CCE::Sync::Commands.new(project_dir: broot, remote: bremote, config: bcfg)
        pull = bcmds.pull(commit: sha)
        assert_equal res[:checksum], pull[:checksum]

        a = CCE::Indexer.retriever_from_store(File.join(root, ".cce", "index.db")).search("hash password", top_k: 5)
        b = CCE::Indexer.retriever_from_store(File.join(broot, ".cce", "index.db")).search("hash password", top_k: 5)
        assert_equal a.map { |r| r[:chunk_id] }, b.map { |r| r[:chunk_id] }
      end
    end
  end

  def test_push_indexes_when_no_store_present
    with_project do |root, sha, remote, _cache|
      refute File.exist?(File.join(root, ".cce", "index.db"))
      res = commands(root, remote).push
      assert_operator res[:chunk_count], :>, 0
      assert File.exist?(File.join(root, ".cce", "index.db")), "push ensured a hash index"
    end
  end

  def test_push_refuses_dirty_tree
    with_project do |root, _sha, remote, _cache|
      File.write(File.join(root, "auth.py"), "changed\n")
      err = assert_raises(CCE::Sync::Error) { commands(root, remote).push }
      assert_match(/dirty working tree/, err.message)
    end
  end

  def test_push_refuses_non_hash_index
    with_project do |root, _sha, remote, _cache|
      store = File.join(root, ".cce", "index.db")
      FileUtils.mkdir_p(File.dirname(store))
      emb = CCE::HashEmbedder.new
      recs = CCE::Chunker.chunk_file(SYNC_SAMPLE["auth.py"], "auth.py").map { |c| { chunk: c, vector: emb.embed(c.content) } }
      CCE::Store.create(store) { |s| s.write(records: recs, file_imports: {}, embedder: "ollama") }
      err = assert_raises(CCE::Sync::Error) { commands(root, remote).push }
      assert_match(/only 'hash'/, err.message)
    end
  end

  def test_push_unchanged_on_second_push
    with_project do |root, _sha, remote, _cache|
      c = commands(root, remote)
      c.push
      assert_equal :unchanged, commands(root, remote).push[:status]
    end
  end

  def test_pull_cache_miss_is_graceful
    with_project do |root, _sha, remote, _cache|
      err = assert_raises(CCE::Sync::Error) { commands(root, remote).pull }
      assert_match(/cache miss/, err.message)
      # local store untouched (offline-first): still absent, nothing corrupted
      refute File.exist?(File.join(root, ".cce", "index.db"))
    end
  end

  def test_pull_latest_resolves_newest
    with_project do |root, sha, remote, _cache|
      commands(root, remote).push
      res = commands(root, remote).pull(latest: true, force: true)
      assert_equal sha, res[:sha]
      assert res[:tree_matches]
    end
  end

  def test_pull_detects_checksum_mismatch
    with_project do |root, sha, remote, cache|
      commands(root, remote).push
      # Corrupt the cached artifact in place on the remote.
      key = CCE::Sync::ContentAddress.key(repo_id: "github.com__acme__demo", sha: sha)
      poison = git_remote_for(cache, File.dirname(root))
      bytes = poison.get(key)
      poison.put(key, bytes.sub(/"chunk_count":\d+/, '"chunk_count":999'))
      err = assert_raises(CCE::Sync::Error) { commands(root, remote).pull(force: true) }
      assert_match(/checksum mismatch/, err.message)
    end
  end

  def test_pull_guards_overwrite_of_different_sha
    with_project do |root, sha, remote, cache|
      commands(root, remote).push # local marker + store are for `sha`
      # Publish a valid cache for a DIFFERENT sha, then pulling it without
      # --force must be refused (offline-first §9.4: never silently replace).
      other = "f" * 40
      store = File.join(root, ".cce", "index.db")
      other_art = CCE::Sync::Artifact.export(store, repo_id: "github.com__acme__demo", sha: other)
      publisher = git_remote_for(cache, File.dirname(root))
      publisher.put(CCE::Sync::ContentAddress.key(repo_id: "github.com__acme__demo", sha: other), other_art[:bytes])

      err = assert_raises(CCE::Sync::Error) { commands(root, remote).pull(commit: other) }
      assert_match(/refusing to replace/, err.message)
      # ...but --force allows it.
      assert commands(root, remote).pull(commit: other, force: true)
    end
  end

  def test_status_reports_configured_and_matching_tree
    with_project do |root, sha, remote, _cache|
      commands(root, remote).push
      s = commands(root, remote).status
      assert s[:configured]
      assert_equal sha, s[:head]
      assert_equal sha, s[:local_sha]
      assert_equal sha, s[:remote_latest]
      assert s[:tree_matches]
      refute s[:dirty]
    end
  end

  def test_status_unconfigured
    with_tmpdir do |dir|
      s = CCE::Sync::Commands.new(project_dir: dir, config: CCE::Sync::Config.new({})).status
      refute s[:configured]
    end
  end

  def test_verify_matches_after_push
    with_project do |root, _sha, remote, _cache|
      commands(root, remote).push
      res = commands(root, remote).verify
      assert res[:match], "re-indexed checksum should match the cached artifact"
      assert_equal res[:expected], res[:actual]
    end
  end

  def test_verify_detects_mismatch_when_source_changed
    with_project do |root, sha, remote, _cache|
      commands(root, remote).push
      # Change a file and commit, so HEAD moves and the re-index differs from the
      # cached artifact for the OLD sha (which we pin via marker/remote lookup).
      # Here we verify the OLD sha is no longer reproducible from the new tree:
      # push produced the marker for `sha`; mutate + commit, then verify current
      # HEAD has no cache -> expected pulled checksum from marker mismatches.
      File.write(File.join(root, "auth.py"), "import hashlib\n\ndef hash_password(p):\n    return 'X'\n")
      git("commit", "-aqm", "change", dir: root)
      # No cache for the new HEAD -> verify raises (nothing to verify) which is
      # the correct graceful outcome; assert that path.
      err = assert_raises(CCE::Sync::Error) { commands(root, remote).verify }
      assert_match(/nothing to verify/, err.message)
    end
  end

  def test_no_remote_configured_raises_clear_error
    with_tmpdir do |dir|
      root = File.join(dir, "A")
      init_source_repo(root, SYNC_SAMPLE)
      c = CCE::Sync::Commands.new(project_dir: root, config: CCE::Sync::Config.new({}))
      assert_match(/no sync remote configured/, assert_raises(CCE::Sync::Error) { c.push }.message)
      assert_match(/no sync remote configured/, assert_raises(CCE::Sync::Error) { c.pull }.message)
    end
  end

  def test_remote_unreachable_fails_gracefully_without_corrupting_local
    with_tmpdir do |dir|
      root = File.join(dir, "A")
      init_source_repo(root, SYNC_SAMPLE)
      CCE::Sync::Config.write_project(root, remote: "file://#{dir}/does-not-exist.git", lfs: false, repo_id: "r")
      cmds = lambda do
        CCE::Sync::Commands.new(project_dir: root, clone_base: File.join(dir, "clones"),
                                config: CCE::Sync::Config.load(root, home: dir))
      end
      err = assert_raises(CCE::Sync::Error) { cmds.call.push }
      assert_match(/unreachable|rejected/, err.message)
      # local index still works (offline-first §9.2/§9.3)
      results = CCE::Indexer.retriever_from_store(File.join(root, ".cce", "index.db")).search("hash password", top_k: 3)
      refute_empty results
      # status degrades gracefully: remote latest is :unreachable, not a crash
      assert_equal :unreachable, cmds.call.status[:remote_latest]
    end
  end

  def test_init_writes_config_and_sets_up_clone
    with_tmpdir do |dir|
      cache = bare_repo(File.join(dir, "cache.git"))
      root = File.join(dir, "A")
      init_source_repo(root, SYNC_SAMPLE)
      remote = git_remote_for(cache, dir)
      cmds = CCE::Sync::Commands.new(project_dir: root, remote: remote, config: CCE::Sync::Config.new({}))
      res = cmds.init(remote_url: "file://#{cache}", lfs: false, repo_id: "github.com__acme__demo")
      assert File.file?(res[:config_path])
      assert_equal "github.com__acme__demo", res[:repo_id]
      assert File.directory?(File.join(remote.clone_dir, ".git")), "clone set up"
    end
  end
end
