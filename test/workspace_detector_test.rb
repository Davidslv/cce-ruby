# WHY: Detection is the root of workspace mode; wrong members poison everything
#      downstream. These pins nail the §3 marker rules, type precedence, package
#      names, ordering, no-nesting, the degenerate single-repo case, and collision
#      suffixing over the committed fixture (SPEC-V2.2 §3, §8).
# WHAT: Unit tests for CCE::Workspace::Detector.

require_relative "test_helper"

class WorkspaceDetectorTest < Minitest::Test
  include TestSupport

  def test_detects_fixture_members_sorted_by_path
    members = CCE::Workspace::Detector.detect(workspace_fixture_dir)
    assert_equal %w[app engines/billing web], members.map(&:path)
    assert_equal %w[app billing web], members.map(&:name)
  end

  def test_types_and_packages
    by_name = CCE::Workspace::Detector.detect(workspace_fixture_dir).to_h { |m| [m.name, m] }
    assert_equal "rails-app", by_name["app"].type
    assert_equal "app", by_name["app"].package
    assert_equal "ruby-engine", by_name["billing"].type
    assert_equal "billing", by_name["billing"].package
    assert_equal "typescript", by_name["web"].type
    assert_equal "web", by_name["web"].package
  end

  def test_members_do_not_nest
    # billing lives under engines/, but engines/ is not itself a member and the
    # detector must not descend into billing/ to find a nested member.
    paths = CCE::Workspace::Detector.detect(workspace_fixture_dir).map(&:path)
    refute(paths.any? { |p| p.start_with?("app/") || p.start_with?("engines/billing/") })
  end

  def test_ruby_gem_without_engine_markers
    with_tmpdir do |dir|
      gem = File.join(dir, "utils")
      FileUtils.mkdir_p(File.join(gem, "lib"))
      File.write(File.join(gem, "utils.gemspec"), "Gem::Specification.new { |s| s.name = \"utils\" }\n")
      File.write(File.join(gem, "lib", "utils.rb"), "module Utils; end\n")
      m = CCE::Workspace::Detector.detect(dir).first
      assert_equal "ruby-gem", m.type
      assert_equal "utils", m.package
    end
  end

  def test_gem_package_falls_back_to_gemspec_stem
    with_tmpdir do |dir|
      gem = File.join(dir, "thing")
      FileUtils.mkdir_p(gem)
      File.write(File.join(gem, "my_lib.gemspec"), "Gem::Specification.new { |s| s.version = \"1\" }\n")
      m = CCE::Workspace::Detector.detect(dir).first
      assert_equal "my_lib", m.package
    end
  end

  def test_javascript_without_tsconfig
    with_tmpdir do |dir|
      pkg = File.join(dir, "front")
      FileUtils.mkdir_p(pkg)
      File.write(File.join(pkg, "package.json"), JSON.generate(name: "front"))
      m = CCE::Workspace::Detector.detect(dir).first
      assert_equal "javascript", m.type
      assert_equal "front", m.package
    end
  end

  def test_js_package_falls_back_to_basename
    with_tmpdir do |dir|
      pkg = File.join(dir, "frontend")
      FileUtils.mkdir_p(pkg)
      File.write(File.join(pkg, "package.json"), "{}")
      m = CCE::Workspace::Detector.detect(dir).first
      assert_equal "frontend", m.package
    end
  end

  def test_degenerate_root_is_sole_member
    with_tmpdir do |dir|
      File.write(File.join(dir, "solo.gemspec"), "Gem::Specification.new { |s| s.name = \"solo\" }\n")
      members = CCE::Workspace::Detector.detect(dir)
      assert_equal 1, members.length
      assert_equal "", members.first.path
      assert_equal "solo", members.first.package
    end
  end

  def test_collision_suffixing_in_path_order
    with_tmpdir do |dir|
      a = File.join(dir, "a", "plugin")
      b = File.join(dir, "b", "plugin")
      [a, b].each do |p|
        FileUtils.mkdir_p(p)
        File.write(File.join(p, "package.json"), JSON.generate(name: File.basename(File.dirname(p))))
      end
      members = CCE::Workspace::Detector.detect(dir)
      assert_equal %w[a/plugin b/plugin], members.map(&:path)
      assert_equal %w[plugin plugin-2], members.map(&:name)
    end
  end
end
