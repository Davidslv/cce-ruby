# WHY: CCE Sync layers an optional, offline-first, content-addressed cache on top
#      of the local-first core (SPEC-SYNC §1). It must never change how any
#      existing command behaves: with no remote configured every command works
#      exactly as before, and a failed push/pull can never break local work.
# WHAT: The CCE::Sync namespace + its single require point + normative constants
#       shared by every implementation so the interchange artifact and the
#       content-address scheme agree bit-for-bit across Ruby and Rust.
# RESPONSIBILITIES:
#   - Own the Sync constants (artifact provenance keys, default clone base,
#     default committer identity, the shareable embedder id).
#   - Require the Sync subsystem in dependency order.
#   - Own no algorithm itself (artifact/address/git/remote/commands live below).

module CCE
  module Sync
    # Raised for user-facing sync errors (no remote, dirty tree, cache miss,
    # checksum mismatch, non-hash embedder). The CLI turns these into a clear,
    # non-zero message; local indexing/search are never affected.
    class Error < StandardError; end

    # Only the deterministic hashing embedder produces shareable, reproducible
    # caches (SPEC-SYNC §1). Ollama/semantic indexes are local-only.
    SHAREABLE_EMBEDDER = "hash"

    # The sync artifact FORMAT-compatibility window (SPEC-SYNC §3). It is a format
    # version, NOT the software version: it only rolls when the interchange
    # artifact/content-address format changes, so caches and the cross-language
    # golden stay valid across additive releases. v2.4 (CCE MCP) is purely
    # additive and does not touch the sync format, so the window stays 2.3.
    SYNC_FORMAT_VERSION = "2.3"

    # Where GitRemote keeps its working clones (SPEC-SYNC §4). Overridable so
    # tests are fully hermetic and never touch a developer's ~/.cce.
    def self.default_clone_base(home: Dir.home)
      File.join(home, ".cce", "sync")
    end

    # The format-compatibility window used in the content address and the manifest
    # (SPEC-SYNC §3). Pinned to SYNC_FORMAT_VERSION, not CCE::VERSION, so a purely
    # additive software release does not invalidate existing caches or roll the
    # cross-language golden.
    def self.cce_version
      SYNC_FORMAT_VERSION
    end

    # Per-member repo_id for workspace sync (SPEC-SYNC §5): a workspace's members
    # share one git origin, so each member is keyed by the base repo_id plus its
    # package, filesystem/URL-safe.
    def self.member_repo_id(base_repo_id, package)
      safe = package.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
      "#{base_repo_id}__#{safe}"
    end
  end
end

require_relative "sync/git"
require_relative "sync/content_address"
require_relative "sync/artifact"
require_relative "sync/config"
require_relative "sync/git_remote"
require_relative "sync/commands"
