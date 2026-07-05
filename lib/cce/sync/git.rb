# WHY: The GitRemote backend drives a real git repository as the cache remote
#      (SPEC-SYNC §4). Every git call must be captured (never inherit the parent
#      stdio), fail loudly with the git output, and carry a deterministic
#      committer identity so hermetic tests need no global git config.
# WHAT: A thin, dependency-free wrapper over the `git` CLI via Open3.
# RESPONSIBILITIES:
#   - Run git in a chosen working directory, returning stdout or raising GitError
#     with the combined output on failure.
#   - Answer the few repository questions the sync engine needs (HEAD sha, dirty
#     working tree, origin url, "is this a repo", current branch).
#   - Commit with an explicit identity and detect whether git / git-lfs exist.
#   - Deliberately NOT own the cache layout or the artifact (those live above).

require "open3"

module CCE
  module Sync
    module Git
      # Raised when a git invocation exits non-zero; carries the git output.
      class GitError < StandardError; end

      # A fixed identity for commits made by the sync engine, so tests and CI
      # need no ambient `user.name`/`user.email`. Real pushes still authenticate
      # through git's own SSH/HTTPS credentials (SPEC-SYNC §6).
      IDENTITY = { name: "CCE Sync", email: "sync@cce.local" }.freeze

      module_function

      # Run `git <args>` (optionally in `dir`) and return stdout. Combined
      # stdout+stderr is captured so failures surface the real git message.
      def run(*args, dir: nil)
        cmd = ["git"]
        cmd += ["-C", dir] if dir
        cmd += args.map(&:to_s)
        out, status = Open3.capture2e(*cmd)
        raise GitError, "#{cmd.join(' ')}\n#{out.strip}" unless status.success?

        out
      end

      # True if the git binary is available.
      def available?
        _out, status = Open3.capture2e("git", "--version")
        status.success?
      rescue StandardError
        false
      end

      # True if the git-lfs binary is available (used to SKIP the LFS smoke test
      # gracefully where it is not installed — core tests never need it).
      def lfs_available?
        _out, status = Open3.capture2e("git", "lfs", "version")
        status.success?
      rescue StandardError
        false
      end

      # True if `dir` is inside a git working tree.
      def repo?(dir)
        _out, status = Open3.capture2e("git", "-C", dir.to_s, "rev-parse", "--git-dir")
        status.success?
      rescue StandardError
        false
      end

      def head_sha(dir)
        run("rev-parse", "HEAD", dir: dir).strip
      end

      # True when the working tree has uncommitted changes (untracked or staged).
      def dirty?(dir)
        !run("status", "--porcelain", dir: dir).strip.empty?
      end

      def current_branch(dir)
        run("rev-parse", "--abbrev-ref", "HEAD", dir: dir).strip
      end

      # The configured origin url, or nil when there is no origin remote.
      def origin_url(dir)
        run("config", "--get", "remote.origin.url", dir: dir).strip
      rescue GitError
        nil
      end

      # Commit staged changes with the sync identity. Passing the identity via
      # `-c` flags avoids depending on any global git config.
      def commit(dir:, message:, identity: IDENTITY)
        run("-c", "user.name=#{identity[:name]}",
            "-c", "user.email=#{identity[:email]}",
            "commit", "-m", message, dir: dir)
      end
    end
  end
end
