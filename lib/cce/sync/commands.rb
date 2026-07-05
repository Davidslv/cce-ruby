# WHY: `cce sync init|push|pull|status|verify` must be offline-first and purely
#      additive: with no remote every command works as before, and a failed
#      push/pull is best-effort and NEVER corrupts the local .cce/ store
#      (SPEC-SYNC §5, §9). This orchestrator holds that contract in one place so
#      the CLI stays a thin formatter.
# WHAT: The per-project sync engine: resolve identity, ensure a hash index,
#       export/import the artifact through a SyncRemote, guard overwrites, and
#       record a local cache marker.
# RESPONSIBILITIES:
#   - init: persist config, set up the working clone, optionally enable git-LFS.
#   - push: refuse a dirty tree / non-hash index, export repo@sha, put to remote.
#   - pull: fetch repo@sha (or --latest), validate the checksum, import into
#     .cce/, guard against silently replacing a different sha without --force.
#   - status/verify: report freshness; rebuild-and-compare the checksum.
#   - Translate every git/remote failure into a clear Sync::Error; local work
#     is never broken.

require "json"
require "tmpdir"
require "fileutils"
require_relative "../indexer"
require_relative "../store"
require_relative "git"
require_relative "artifact"
require_relative "content_address"
require_relative "config"
require_relative "git_remote"

module CCE
  module Sync
    class Commands
      MARKER = "sync.json"

      attr_reader :project_dir, :config

      # @param project_dir [String] the repo to sync
      # @param config [Sync::Config] resolved sync.* config
      # @param remote [SyncRemote, nil] injected backend (tests); else built from
      #   config lazily
      # @param clone_base [String] where GitRemote keeps working clones
      def initialize(project_dir:, config: nil, remote: nil, clone_base: Sync.default_clone_base, home: Dir.home)
        @project_dir = File.expand_path(project_dir)
        @config = config || Sync::Config.load(@project_dir, home: home)
        @remote = remote
        @clone_base = clone_base
      end

      # ---- init ----------------------------------------------------------------

      # Configure the remote and set up the local working clone. With lfs, writes
      # .gitattributes for `*.cce` and enables git-LFS in the clone.
      def init(remote_url:, lfs: true, repo_id: nil)
        raise Error, "sync init requires --remote <git-url>" if remote_url.to_s.empty?

        path = Sync::Config.write_project(@project_dir, remote: remote_url, lfs: lfs, repo_id: repo_id)
        @config = Sync::Config.load(@project_dir, home: Dir.home)
        # If a remote was injected (tests) keep it; otherwise it is built lazily
        # from the freshly written config.
        r = remote
        guard_remote { r.ensure_clone! }
        guard_remote { r.init_lfs! } if lfs
        { config_path: path, remote: remote_url, lfs: lfs, repo_id: safe_repo_id, clone_dir: r.clone_dir }
      end

      # ---- push ----------------------------------------------------------------

      def push(commit: nil)
        require_configured!
        require_repo!
        raise Error, "refusing to push a dirty working tree; commit first (SPEC-SYNC §5)" if Git.dirty?(@project_dir)

        head = Git.head_sha(@project_dir)
        sha = normalize_commit(commit, head)
        raise Error, "cannot push #{sha[0, 12]}: it is not HEAD (push exports the current working tree)" if sha != head

        store = ensure_hash_index!
        repo_id = resolve_repo_id
        art = Artifact.export(store, repo_id: repo_id, sha: sha, built_at: commit_time(sha))
        key = ContentAddress.key(repo_id: repo_id, sha: sha)
        result = guard_remote { remote.put(key, art[:bytes]) }
        write_marker(repo_id: repo_id, sha: sha, key: key, checksum: art[:checksum])
        {
          status: result, key: key, checksum: art[:checksum], sha: sha,
          repo_id: repo_id, chunk_count: art[:chunk_count]
        }
      end

      # ---- pull ----------------------------------------------------------------

      def pull(commit: nil, latest: false, force: false)
        require_configured!
        repo_id = resolve_repo_id
        sha = resolve_pull_sha(commit: commit, latest: latest, repo_id: repo_id)
        key = ContentAddress.key(repo_id: repo_id, sha: sha)

        bytes = guard_remote { remote.get(key) }
        raise Error, "cache miss for #{key} (no cached index for this commit; run `cce index` locally)" if bytes.nil?
        raise Error, "checksum mismatch: cached artifact for #{sha[0, 12]} is corrupt" unless Artifact.checksum_valid?(bytes)

        store = default_store
        guard_overwrite!(sha, force)
        manifest = Artifact.import(bytes, store)
        write_marker(repo_id: repo_id, sha: sha, key: key, checksum: manifest["checksum"])

        {
          sha: sha, key: key, checksum: manifest["checksum"], repo_id: repo_id,
          chunk_count: manifest["chunk_count"], tree_matches: tree_matches?(sha), forced: force
        }
      end

      # ---- status --------------------------------------------------------------

      def status
        return { configured: false } unless @config.configured?

        repo_id = safe_repo_id
        head = Git.repo?(@project_dir) ? Git.head_sha(@project_dir) : nil
        marker = read_marker
        remote_latest =
          if repo_id
            begin
              remote.latest(ContentAddress.prefix(repo_id: repo_id))
            rescue Git::GitError, Error
              :unreachable
            end
          end
        {
          configured: true, remote: @config.remote, repo_id: repo_id,
          head: head, dirty: (head ? Git.dirty?(@project_dir) : nil),
          local_sha: marker && marker["sha"], local_checksum: marker && marker["checksum"],
          remote_latest: remote_latest,
          tree_matches: (head && marker && marker["sha"] == head && !Git.dirty?(@project_dir))
        }
      end

      # ---- verify --------------------------------------------------------------

      # Re-index the working tree and confirm the cached artifact's checksum
      # (the paranoid rebuild-and-compare; SPEC-SYNC §5).
      def verify(commit: nil)
        require_configured!
        require_repo!
        raise Error, "cannot verify a dirty working tree; commit or stash first" if Git.dirty?(@project_dir)

        head = Git.head_sha(@project_dir)
        sha = normalize_commit(commit, head)
        raise Error, "cannot verify #{sha[0, 12]}: it is not the working tree (checkout it first)" if sha != head

        repo_id = resolve_repo_id
        expected = expected_checksum(repo_id, sha)
        actual = rebuild_checksum(repo_id, sha)
        { sha: sha, repo_id: repo_id, expected: expected, actual: actual, match: expected == actual }
      end

      # --------------------------------------------------------------------------

      def default_store
        File.join(@project_dir, ".cce", "index.db")
      end

      private

      def remote
        @remote ||= GitRemote.for_url(@config.remote, clone_base: @clone_base, lfs: @config.lfs?)
      end

      def require_configured!
        raise Error, "no sync remote configured (run `cce sync init --remote <git-url>`)" unless @config.configured?
      end

      def require_repo!
        raise Error, "#{@project_dir} is not a git repository" unless Git.repo?(@project_dir)
      end

      # Resolve the repo_id: an explicit override wins, else the git origin.
      def resolve_repo_id
        return @config.repo_id if @config.repo_id

        url = Git.repo?(@project_dir) ? Git.origin_url(@project_dir) : nil
        raise Error, "cannot determine repo_id: set sync.repo_id (or add a git origin)" if url.nil?

        ContentAddress.normalize_repo_id(url)
      end

      def safe_repo_id
        resolve_repo_id
      rescue Error
        nil
      end

      def normalize_commit(commit, head)
        return head if commit.nil?

        Git.run("rev-parse", commit, dir: @project_dir).strip
      rescue Git::GitError
        raise Error, "unknown commit: #{commit}"
      end

      def resolve_pull_sha(commit:, latest:, repo_id:)
        if latest
          sha = guard_remote { remote.latest(ContentAddress.prefix(repo_id: repo_id)) }
          raise Error, "no cached index found for #{repo_id}" if sha.nil?

          sha
        elsif commit
          Git.repo?(@project_dir) ? normalize_commit(commit, nil) : commit
        else
          require_repo!
          Git.head_sha(@project_dir)
        end
      end

      # Ensure a shareable hash index exists; refuse a non-hash store (§1).
      def ensure_hash_index!
        store = default_store
        if File.exist?(store)
          embedder = read_embedder(store)
          unless embedder == SHAREABLE_EMBEDDER
            raise Error, "index at #{store} was built with the '#{embedder}' embedder; " \
                         "only '#{SHAREABLE_EMBEDDER}' indexes are shareable — " \
                         "re-index with `cce index #{@project_dir}`"
          end
        else
          CCE::Indexer.index(@project_dir, store_path: store, embedder: SHAREABLE_EMBEDDER)
        end
        store
      end

      def read_embedder(store_path)
        s = CCE::Store.open(store_path)
        begin
          s.embedder_name
        ensure
          s.close
        end
      end

      # Refuse to replace a local cache for a DIFFERENT sha without --force
      # (offline-first guarantee §9.4). A store present without a marker (a
      # hand-built local index) is also protected.
      def guard_overwrite!(sha, force)
        return if force
        return unless File.exist?(default_store)

        marker = read_marker
        return if marker && marker["sha"] == sha

        current = marker ? marker["sha"][0, 12] : "a local index"
        raise Error, "refusing to replace #{current} with #{sha[0, 12]}; pass --force to overwrite"
      end

      def tree_matches?(sha)
        return false unless Git.repo?(@project_dir)

        Git.head_sha(@project_dir) == sha && !Git.dirty?(@project_dir)
      end

      def expected_checksum(repo_id, sha)
        key = ContentAddress.key(repo_id: repo_id, sha: sha)
        bytes = guard_remote { remote.get(key) }
        if bytes
          Artifact.parse(bytes)[:manifest]["checksum"]
        else
          marker = read_marker
          raise Error, "nothing to verify for #{sha[0, 12]} (pull it first)" unless marker && marker["sha"] == sha

          marker["checksum"]
        end
      end

      # Rebuild the index for the working tree in a throwaway store and return
      # the artifact checksum — the deterministic proof of the cache's contents.
      def rebuild_checksum(repo_id, sha)
        Dir.mktmpdir("cce-verify") do |tmp|
          store = File.join(tmp, "verify.db")
          CCE::Indexer.index(@project_dir, store_path: store, embedder: SHAREABLE_EMBEDDER)
          Artifact.export(store, repo_id: repo_id, sha: sha)[:checksum]
        end
      end

      def commit_time(sha)
        Git.run("show", "-s", "--format=%cI", sha, dir: @project_dir).strip
      rescue Git::GitError
        ""
      end

      def marker_path
        File.join(@project_dir, ".cce", MARKER)
      end

      def read_marker
        return nil unless File.file?(marker_path)

        JSON.parse(File.read(marker_path))
      rescue StandardError
        nil
      end

      def write_marker(repo_id:, sha:, key:, checksum:)
        FileUtils.mkdir_p(File.dirname(marker_path))
        File.write(marker_path, JSON.pretty_generate(
          "repo_id" => repo_id, "sha" => sha, "key" => key,
          "checksum" => checksum, "cce_version" => Sync.cce_version
        ))
      end

      # Translate any git/remote failure into an offline-friendly Sync::Error so
      # a network/auth problem never crashes the CLI or corrupts local state.
      def guard_remote
        yield
      rescue Git::GitError => e
        raise Error, "sync remote unreachable or rejected the operation: #{e.message.lines.first&.strip}"
      end
    end
  end
end
