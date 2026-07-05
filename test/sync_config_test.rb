# WHY: Sync is opt-in and layered: a global ~/.cce/config.yml under a per-project
#      .cce/config, with absent config meaning pure local CCE (SPEC-SYNC §8, §9.1).
# WHAT: Unit tests for CCE::Sync::Config load/merge/write and defaults.

require_relative "test_helper"

class SyncConfigTest < Minitest::Test
  include TestSupport

  Cfg = CCE::Sync::Config

  def test_absent_config_is_unconfigured_with_defaults
    with_tmpdir do |dir|
      c = Cfg.load(dir, home: dir)
      refute c.configured?
      assert_nil c.remote
      assert c.lfs?, "lfs defaults to true"
      assert_equal "all", c.retention
      refute c.auto_pull?
    end
  end

  def test_project_overrides_global
    with_tmpdir do |dir|
      home = File.join(dir, "home"); FileUtils.mkdir_p(File.join(home, ".cce"))
      File.write(File.join(home, ".cce", "config.yml"),
                 "sync:\n  remote: file:///global.git\n  lfs: true\n")
      Cfg.write_project(dir, remote: "file:///project.git", lfs: false, repo_id: "r")
      c = Cfg.load(dir, home: home)
      assert_equal "file:///project.git", c.remote
      refute c.lfs?
      assert_equal "r", c.repo_id
    end
  end

  def test_global_used_when_no_project
    with_tmpdir do |dir|
      home = File.join(dir, "home"); FileUtils.mkdir_p(File.join(home, ".cce"))
      File.write(File.join(home, ".cce", "config.yml"), "sync:\n  remote: file:///global.git\n")
      c = Cfg.load(dir, home: home)
      assert_equal "file:///global.git", c.remote
      assert c.configured?
    end
  end

  def test_write_project_is_idempotent_and_preserves_other_keys
    with_tmpdir do |dir|
      path = Cfg.project_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "other: keep\n")
      Cfg.write_project(dir, remote: "file:///r.git", lfs: true, repo_id: nil, retention: "keep-last-5", auto_pull: true)
      data = YAML.safe_load(File.read(path))
      assert_equal "keep", data["other"]
      assert_equal "file:///r.git", data["sync"]["remote"]
      assert_equal "keep-last-5", data["sync"]["retention"]
      assert_equal true, data["sync"]["auto_pull"]
      refute data["sync"].key?("repo_id")
    end
  end

  def test_malformed_yaml_is_treated_as_absent
    with_tmpdir do |dir|
      path = Cfg.project_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, ":\n  - broken: [")
      c = Cfg.load(dir, home: dir)
      refute c.configured?
    end
  end
end
