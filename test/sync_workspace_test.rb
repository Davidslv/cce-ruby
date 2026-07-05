# WHY: Sync is workspace-aware: `push/pull --workspace` iterates members, each
#      keyed by its own repo_id@sha (SPEC-SYNC §5), composing with SPEC-V2.2.
#      A member's cache must round-trip independently and not collide with a
#      sibling that shares the same git origin.
# WHAT: Integration test for workspace sync via the CLI over a local bare cache.

require_relative "test_helper"

class SyncWorkspaceTest < Minitest::Test
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

  def test_workspace_push_pull_keys_each_member_separately
    with_workspace_fixture do |root|
      Dir.mktmpdir("cce-ws-sync") do |dir|
        home = File.join(dir, "home"); FileUtils.mkdir_p(home)
        cache = bare_repo(File.join(dir, "cache.git"))
        # make the workspace a git repo with an origin (members share it)
        git("init", "-q", dir: root)
        git("symbolic-ref", "HEAD", "refs/heads/main", dir: root)
        File.write(File.join(root, ".gitignore"), ".cce/\n")
        git("add", "-A", dir: root)
        git("commit", "-qm", "init", dir: root)
        git("remote", "add", "origin", "file:///source.git", dir: root)

        CCE::Workspace::Manifest.detect(root).write(root)
        CCE::Workspace::Indexer.index(root)
        CCE::Sync::Config.write_project(root, remote: "file://#{cache}", lfs: false, repo_id: "github.com__acme__eco")

        code, out, err = run_cli(["sync", "push", "--workspace", root], home: home)
        assert_equal 0, code, err
        assert_match(/app/, out)
        assert_match(/billing/, out)
        assert_match(/web/, out)

        # each member is cached under its OWN prefix (repo_id__package)
        remote = git_remote_for(cache, dir)
        %w[app billing web].each do |pkg|
          assert_equal 1, remote.list("hash/2.3/github.com__acme__eco__#{pkg}").length,
                       "expected a cache for member #{pkg}"
        end

        # pull into a fresh copy of the workspace tree
        broot = File.join(dir, "B")
        FileUtils.cp_r(root, broot)
        # drop only the member index stores (keep the workspace manifest) so pull
        # must install them from the cache
        FileUtils.rm_f(Dir.glob(File.join(broot, "**", ".cce", "index.db")))
        FileUtils.rm_f(Dir.glob(File.join(broot, "**", ".cce", "sync.json")))
        CCE::Sync::Config.write_project(broot, remote: "file://#{cache}", lfs: false, repo_id: "github.com__acme__eco")

        code2, out2, err2 = run_cli(["sync", "pull", "--workspace", "--force", broot], home: home)
        assert_equal 0, code2, err2
        assert_match(/installed/, out2)
        # a member store now exists and is searchable
        billing_store = File.join(broot, "engines", "billing", ".cce", "index.db")
        assert File.exist?(billing_store)
      end
    end
  end
end
