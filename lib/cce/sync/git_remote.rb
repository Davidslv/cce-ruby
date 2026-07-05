# WHY: The default and recommended remote backend is a git repository, keyed by
#      the content address, so permissions/transport/auth are git's own and no
#      RBAC is reinvented (SPEC-SYNC §4, §6). Distinct shas are distinct files,
#      so the only race is git-ref advancement — handled with fetch-rebase-retry.
# WHAT: A SyncRemote implementation over a local working clone of a git repo,
#       with optional git-LFS for the large `*.cce` blobs.
# RESPONSIBILITIES:
#   - Lazily clone the remote into a working directory (default ~/.cce/sync/<id>).
#   - put(key, bytes) = write at the content-addressed path, commit, push (fetch +
#     rebase + retry on a non-fast-forward race).
#   - get/has(key) = fetch, reset to the remote branch, read the file.
#   - list(prefix)/latest(prefix) over the cache tree.
#   - init_lfs! writes .gitattributes for `*.cce` and enables LFS in the clone.
#   - Deliberately NOT own the artifact format or the content-address scheme.

require "fileutils"
require "digest"
require_relative "git"

module CCE
  module Sync
    class GitRemote
      PUSH_RETRIES = 5
      GITATTRIBUTES = "*.cce filter=lfs diff=lfs merge=lfs -text\n"

      attr_reader :url, :clone_dir, :lfs

      # @param url [String] the git remote url (any transport git understands)
      # @param clone_dir [String] where the working clone lives
      # @param lfs [Boolean] whether `*.cce` blobs go through git-LFS
      def initialize(url:, clone_dir:, lfs: false)
        @url = url
        @clone_dir = clone_dir
        @lfs = lfs
      end

      # A stable, filesystem-safe id for a remote url (used to name its clone dir
      # under the clone base): normalized repo_id + a short digest to avoid any
      # collision between two urls that normalize alike.
      def self.remote_id(url)
        base =
          begin
            ContentAddress.normalize_repo_id(url)
          rescue StandardError
            "remote"
          end
        "#{base}-#{Digest::SHA256.hexdigest(url.to_s)[0, 8]}"
      end

      # Build a GitRemote for a url under a clone base (default ~/.cce/sync).
      def self.for_url(url, clone_base: Sync.default_clone_base, lfs: false)
        new(url: url, clone_dir: File.join(clone_base, remote_id(url)), lfs: lfs)
      end

      # Ensure the working clone exists (cloning on first use).
      def ensure_clone!
        return self if File.directory?(File.join(@clone_dir, ".git"))

        FileUtils.mkdir_p(File.dirname(@clone_dir))
        Git.run("clone", @url, @clone_dir)
        Git.run("lfs", "install", "--local", dir: @clone_dir) if @lfs
        self
      end

      # Write .gitattributes so `*.cce` uses git-LFS, and enable LFS in the clone.
      # Committed + pushed so every clone inherits the filter (SPEC-SYNC §4).
      def init_lfs!(message: "cce sync: enable git-LFS for *.cce")
        ensure_clone!
        Git.run("lfs", "install", "--local", dir: @clone_dir)
        path = File.join(@clone_dir, ".gitattributes")
        return self if File.exist?(path) && File.read(path).include?("*.cce")

        File.write(path, GITATTRIBUTES)
        Git.run("add", ".gitattributes", dir: @clone_dir)
        Git.commit(dir: @clone_dir, message: message)
        push_with_retry
        self
      end

      # True if the cache holds `key`.
      def has(key)
        !get(key).nil?
      end

      # Fetch the latest remote state and read the artifact at `key`, or nil.
      def get(key)
        ensure_clone!
        sync_down!
        path = File.join(@clone_dir, key)
        File.exist?(path) ? File.binread(path) : nil
      end

      # Write `bytes` at `key`, commit, and push (fetch-rebase-retry on a race).
      def put(key, bytes, message: nil)
        ensure_clone!
        sync_down!
        path = File.join(@clone_dir, key)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
        Git.run("add", "--", key, dir: @clone_dir)
        return :unchanged if nothing_staged?

        Git.commit(dir: @clone_dir, message: message || "cce sync: cache #{key}")
        push_with_retry
        :pushed
      end

      # All sha basenames stored under a listing prefix.
      def list(prefix)
        ensure_clone!
        sync_down!
        dir = File.join(@clone_dir, prefix)
        return [] unless File.directory?(dir)

        Dir.glob(File.join(dir, "*.cce")).sort.map { |f| File.basename(f, ".cce") }
      end

      # The most recently committed sha under a prefix (SPEC-SYNC §4 latest).
      def latest(prefix)
        ensure_clone!
        sync_down!
        dir = File.join(@clone_dir, prefix)
        return nil unless File.directory?(dir)

        files = Dir.glob(File.join(dir, "*.cce"))
        return nil if files.empty?

        newest = files.max_by { |f| commit_time(f) }
        File.basename(newest, ".cce")
      end

      private

      # Fetch and hard-reset the working clone onto the remote branch, so reads
      # see the latest cache. On an empty remote (no branch yet) this is a no-op:
      # the first push will seed the branch. Local un-pushed commits only exist
      # transiently inside `put`, which never calls this after committing.
      def sync_down!
        Git.run("fetch", "origin", dir: @clone_dir)
        branch = current_branch
        Git.run("reset", "--hard", "origin/#{branch}", dir: @clone_dir) if remote_branch_exists?(branch)
      end

      # Push HEAD; on a non-fast-forward race, fetch + rebase and retry. Because
      # every sha is a distinct file, a rebase never hits a content conflict.
      def push_with_retry
        branch = current_branch
        attempts = 0
        begin
          Git.run("push", "origin", "HEAD:#{branch}", dir: @clone_dir)
        rescue Git::GitError => e
          attempts += 1
          raise e if attempts > PUSH_RETRIES

          Git.run("fetch", "origin", dir: @clone_dir)
          Git.run("rebase", "origin/#{branch}", dir: @clone_dir) if remote_branch_exists?(branch)
          retry
        end
      end

      def nothing_staged?
        Git.run("status", "--porcelain", dir: @clone_dir).strip.empty?
      end

      # The clone's current branch. `symbolic-ref` works even on an unborn branch
      # (a fresh clone of an empty repo), so first-push is handled.
      def current_branch
        Git.run("symbolic-ref", "--short", "HEAD", dir: @clone_dir).strip
      rescue Git::GitError
        "main"
      end

      def remote_branch_exists?(branch)
        out = Git.run("ls-remote", "--heads", "origin", branch, dir: @clone_dir).strip
        !out.empty?
      rescue Git::GitError
        false
      end

      def commit_time(file)
        rel = file.sub("#{@clone_dir}/", "")
        out = Git.run("log", "-1", "--format=%ct", "--", rel, dir: @clone_dir).strip
        out.empty? ? 0 : out.to_i
      rescue Git::GitError
        0
      end
    end
  end
end
