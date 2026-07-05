# WHY: The cross-member graph is the Level-1 relationship map; it must contain
#      exactly the declared edges, deterministically ordered, and round-trip through
#      workspace-graph.json (§5, §8).
# WHAT: Unit tests for CCE::Workspace::Graph.

require_relative "test_helper"

class WorkspaceGraphTest < Minitest::Test
  include TestSupport

  def test_fixture_has_exactly_one_edge
    manifest = CCE::Workspace::Manifest.detect(workspace_fixture_dir)
    graph = CCE::Workspace::Graph.build(workspace_fixture_dir, manifest)
    assert_equal %w[app billing web], graph[:members]
    assert_equal [{ from: "app", to: "billing", via: "gemfile" }], graph[:edges]
  end

  def test_edges_are_sorted_and_unique
    with_tmpdir do |root|
      # app depends on billing via both Gemfile and its gemspec; z depends on app.
      make_member(root, "app", :rails)
      File.write(File.join(root, "app", "app.gemspec"), "Gem::Specification.new { |s| s.name = \"app\"; s.add_dependency \"billing\" }\n")
      File.write(File.join(root, "app", "Gemfile"), "gem \"billing\"\ngem \"billing\"\n")
      make_gem(root, "billing")
      make_member(root, "zed", :js, deps: { "app" => "1" })

      manifest = CCE::Workspace::Manifest.detect(root)
      edges = CCE::Workspace::Graph.build(root, manifest)[:edges]
      assert_equal(
        [
          { from: "app", to: "billing", via: "gemfile" },
          { from: "app", to: "billing", via: "gemspec" },
          { from: "zed", to: "app", via: "package.json" }
        ], edges
      )
    end
  end

  def test_write_and_load_round_trip
    with_workspace_fixture do |root|
      manifest = CCE::Workspace::Manifest.detect(root)
      graph = CCE::Workspace::Graph.build(root, manifest)
      path = CCE::Workspace::Graph.write(root, graph)
      assert_equal CCE::Workspace::Graph.path_for(root), path
      loaded = CCE::Workspace::Graph.load(root)
      assert_equal graph[:members], loaded[:members]
      assert_equal graph[:edges], loaded[:edges]
    end
  end

  def test_load_absent_graph_is_empty
    with_tmpdir do |root|
      assert_equal({ members: [], edges: [] }, CCE::Workspace::Graph.load(root))
    end
  end

  private

  def make_member(root, name, kind, deps: {})
    dir = File.join(root, name)
    FileUtils.mkdir_p(File.join(dir, "config"))
    case kind
    when :rails
      File.write(File.join(dir, "config", "application.rb"), "module App; end\n")
    when :js
      File.write(File.join(dir, "package.json"), JSON.generate(name: name, dependencies: deps))
    end
  end

  def make_gem(root, name)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.gemspec"), "Gem::Specification.new { |s| s.name = \"#{name}\" }\n")
  end
end
