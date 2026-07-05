# WHY: A workspace is an ecosystem of related codebases (a Rails app + engines + a
#      frontend) that a team wants to search as one whole while each member stays
#      isolated in its own store (SPEC-V2.2 §1). This file is the single namespace
#      and require point for workspace mode, keeping its constants normative and in
#      one place so both language implementations agree bit-for-bit.
# WHAT: The CCE::Workspace namespace + its normative constants + a shared Error.
# RESPONSIBILITIES:
#   - Own the SPEC-V2.2 §1 constants (file names, graph-bonus bounds).
#   - Require the workspace subsystem in dependency order.
#   - Own no algorithm itself (detection/manifest/graph/federation live below).

module CCE
  module Workspace
    # Normative constants (SPEC-V2.2 §1).
    WORKSPACE_FILE            = "workspace.yml"
    WORKSPACE_GRAPH_FILE      = "workspace-graph.json"
    CCE_DIR                   = ".cce"
    MANIFEST_VERSION          = 1
    GRAPH_MAX_BONUS_MEMBERS   = 2
    GRAPH_BONUS_MEMBER_CHUNKS = 2

    # Raised for user-facing workspace errors (missing manifest, unknown package).
    class Error < StandardError; end

    module_function

    # Absolute path to the workspace metadata directory for a root.
    def cce_dir(root)
      File.join(File.expand_path(root), CCE_DIR)
    end

    # Absolute path to a member's store (identical layout to a standalone index).
    def member_store_path(root, member)
      File.join(File.expand_path(root), member.path, CCE_DIR, "index.db")
    end

    # Absolute path to a member's metrics log.
    def member_metrics_path(root, member)
      File.join(File.expand_path(root), member.path, CCE_DIR, Metrics::FILE)
    end
  end
end

require_relative "workspace/detector"
require_relative "workspace/manifest"
require_relative "workspace/dependencies"
require_relative "workspace/graph"
require_relative "workspace/indexer"
require_relative "workspace/federation"
require_relative "workspace/stats"
require_relative "workspace/dashboard"
