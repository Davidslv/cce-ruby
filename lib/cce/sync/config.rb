# WHY: Sync is opt-in and per-project: a repo points at a sync remote via config,
#      and absent config means pure local CCE (SPEC-SYNC §8, §9.1). Configuration
#      layers a global ~/.cce/config.yml under a per-project .cce/config so a
#      workspace can point different projects at different remotes (§6).
# WHAT: Load/merge the sync.* config and write the per-project block on `init`.
# RESPONSIBILITIES:
#   - Read global then project YAML, project overriding, exposing only sync.*.
#   - Provide typed accessors with the spec defaults (lfs=true, retention=all).
#   - Persist a project sync block deterministically on `sync init`.
#   - Own no git or artifact logic.

require "yaml"
require "fileutils"

module CCE
  module Sync
    class Config
      GLOBAL_RELATIVE = File.join(".cce", "config.yml")
      PROJECT_RELATIVE = File.join(".cce", "config")

      attr_reader :data

      def initialize(data = {})
        @data = data || {}
      end

      # Merge global (~/.cce/config.yml) under project (<dir>/.cce/config).
      def self.load(project_dir, home: Dir.home)
        global = read_yaml(File.join(home, GLOBAL_RELATIVE))
        project = read_yaml(File.join(project_dir, PROJECT_RELATIVE))
        merged = {}
        merged.merge!(sync_block(global))
        merged.merge!(sync_block(project))
        new(merged)
      end

      def self.sync_block(doc)
        return {} unless doc.is_a?(Hash)

        block = doc["sync"]
        block.is_a?(Hash) ? block : {}
      end

      def self.read_yaml(path)
        return nil unless File.file?(path)

        YAML.safe_load(File.read(path)) || {}
      rescue StandardError
        nil
      end

      # Absolute path to the project config file for a dir.
      def self.project_path(project_dir)
        File.join(project_dir, PROJECT_RELATIVE)
      end

      # Write (or replace) the sync block in a project's .cce/config.
      def self.write_project(project_dir, remote:, lfs: true, repo_id: nil, retention: nil, auto_pull: nil)
        path = project_path(project_dir)
        FileUtils.mkdir_p(File.dirname(path))
        existing = read_yaml(path) || {}
        block = { "remote" => remote, "lfs" => lfs }
        block["repo_id"] = repo_id if repo_id
        block["retention"] = retention if retention
        block["auto_pull"] = auto_pull unless auto_pull.nil?
        existing["sync"] = block
        File.write(path, YAML.dump(existing))
        path
      end

      def remote
        val = @data["remote"]
        val.to_s.empty? ? nil : val
      end

      def repo_id
        val = @data["repo_id"]
        val.to_s.empty? ? nil : val
      end

      def lfs?
        @data.key?("lfs") ? !!@data["lfs"] : true
      end

      def auto_pull?
        !!@data["auto_pull"]
      end

      def retention
        @data["retention"] || "all"
      end

      def configured?
        !remote.nil?
      end
    end
  end
end
