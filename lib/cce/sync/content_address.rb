# WHY: A cache is content-addressed by its identity so distinct commits are
#      distinct files that never conflict in content, and any teammate/CI/engine
#      resolves the same repo@sha to the same path (SPEC-SYNC §3). The address
#      must be derived deterministically and identically across implementations.
# WHAT: repo_id normalization from a git origin url + the content-address key.
# RESPONSIBILITIES:
#   - Normalize scp-like (git@host:org/repo.git), URL (https/ssh/file://) and
#     bare-path origins into a stable "<host>__<org>__<repo>" repo_id.
#   - Build the "<embedder>/<cce_ver>/<repo_id>/<sha>.cce" cache key and its
#     "<embedder>/<cce_ver>/<repo_id>" listing prefix.
#   - Own no git or network access (that is Git/GitRemote).

module CCE
  module Sync
    module ContentAddress
      module_function

      # Normalize a git origin url to a repo_id: host + path segments joined by
      # "__", with any ".git" suffix and leading slashes stripped and the host
      # lower-cased. Examples:
      #   git@github.com:acme/billing.git      -> github.com__acme__billing
      #   https://github.com/acme/billing.git  -> github.com__acme__billing
      #   ssh://git@host:22/org/repo           -> host__org__repo
      #   file:///tmp/remote.git               -> remote
      # A configured `sync.repo_id` / `--repo-id` override bypasses this entirely
      # (recommended for the cross-language golden fixture, so both engines key on
      # the exact same string).
      def normalize_repo_id(origin_url)
        raise Error, "cannot derive repo_id: no origin url" if origin_url.to_s.strip.empty?

        u = origin_url.to_s.strip.sub(/\.git\z/, "")
        host, path =
          if (m = u.match(/\A[\w.+-]+@([^:\/]+):(.+)\z/)) # scp-like git@host:org/repo
            [m[1], m[2]]
          elsif (m = u.match(%r{\A[a-zA-Z][\w+.\-]*://(?:[^@/]+@)?([^/]+)/(.+)\z})) # url
            [strip_port(m[1]), m[2]]
          else # bare path or unknown
            ["", u.sub(%r{\A/+}, "")]
          end

        segs = (host.to_s.downcase.split("/") + path.to_s.split("/")).reject(&:empty?)
        raise Error, "cannot derive repo_id from #{origin_url.inspect}" if segs.empty?

        segs.join("__")
      end

      # The content-address key for a cache blob (SPEC-SYNC §3).
      def key(repo_id:, sha:, cce_version: Sync.cce_version, embedder: SHAREABLE_EMBEDDER)
        "#{embedder}/#{cce_version}/#{repo_id}/#{sha}.cce"
      end

      # The directory prefix under which every sha for a repo_id is listed.
      def prefix(repo_id:, cce_version: Sync.cce_version, embedder: SHAREABLE_EMBEDDER)
        "#{embedder}/#{cce_version}/#{repo_id}"
      end

      def strip_port(host)
        host.sub(/:\d+\z/, "")
      end
    end
  end
end
