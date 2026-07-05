# WHY: The manifest is the reviewable contract for a workspace; its YAML must be
#      deterministic (§2), refuse to clobber a hand-edited file without --force, and
#      round-trip a hand-written file's member order as-is.
# WHAT: Unit tests for CCE::Workspace::Manifest.

require_relative "test_helper"

class WorkspaceManifestTest < Minitest::Test
  include TestSupport

  def test_deterministic_yaml_shape
    manifest = CCE::Workspace::Manifest.detect(workspace_fixture_dir)
    expected = <<~YAML
      version: 1
      name: workspace
      members:
        - name: app
          path: app
          type: rails-app
          package: app
        - name: billing
          path: engines/billing
          type: ruby-engine
          package: billing
        - name: web
          path: web
          type: typescript
          package: web
    YAML
    # `name` is the fixture-root basename, which is "workspace" only when copied
    # under that name; compare structure independent of the root basename.
    yaml = manifest.to_yaml.sub(/^name: .*$/, "name: workspace")
    assert_equal expected, yaml
  end

  def test_write_then_load_round_trips
    with_workspace_fixture do |root|
      manifest = CCE::Workspace::Manifest.detect(root)
      path = manifest.write(root)
      assert_equal CCE::Workspace::Manifest.path_for(root), path

      loaded = CCE::Workspace::Manifest.load(root)
      assert_equal manifest.members.map(&:to_h), loaded.members.map(&:to_h)
    end
  end

  def test_refuses_overwrite_without_force
    with_workspace_fixture do |root|
      manifest = CCE::Workspace::Manifest.detect(root)
      manifest.write(root)
      err = assert_raises(CCE::Workspace::Error) { manifest.write(root) }
      assert_match(/already exists/, err.message)
      assert manifest.write(root, force: true)
    end
  end

  def test_load_missing_manifest_raises_with_hint
    with_tmpdir do |dir|
      err = assert_raises(CCE::Workspace::Error) { CCE::Workspace::Manifest.load(dir) }
      assert_match(/workspace init/, err.message)
    end
  end

  def test_hand_written_member_order_is_honoured
    with_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".cce"))
      File.write(CCE::Workspace::Manifest.path_for(root), <<~YAML)
        version: 1
        name: custom
        members:
          - name: web
            path: web
            type: typescript
            package: web
          - name: app
            path: app
            type: rails-app
            package: app
      YAML
      loaded = CCE::Workspace::Manifest.load(root)
      assert_equal %w[web app], loaded.members.map(&:name)
      assert_equal "custom", loaded.name
    end
  end

  def test_empty_workspace_yaml
    with_tmpdir do |dir|
      manifest = CCE::Workspace::Manifest.new(version: 1, name: "empty", members: [])
      assert_match(/members: \[\]/, manifest.to_yaml)
      manifest.write(dir)
      assert_empty CCE::Workspace::Manifest.load(dir).members
    end
  end
end
