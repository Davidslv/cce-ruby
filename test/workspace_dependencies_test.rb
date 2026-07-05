# WHY: Cross-member edges are only as trustworthy as the manifest-parsing under
#      them. Each extractor (gemspec, Gemfile, package.json) is pinned separately
#      so a regex change cannot silently drop or invent a dependency (§5).
# WHAT: Unit tests for CCE::Workspace::Dependencies.

require_relative "test_helper"

class WorkspaceDependenciesTest < Minitest::Test
  include TestSupport

  def test_gemspec_dependencies
    with_tmpdir do |dir|
      File.write(File.join(dir, "x.gemspec"), <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "x"
          spec.add_dependency "billing"
          spec.add_runtime_dependency("logging")
          spec.add_development_dependency "rspec"
        end
      RUBY
      deps = CCE::Workspace::Dependencies.extract(dir)
      assert_equal [%w[billing gemspec], %w[logging gemspec], %w[rspec gemspec]],
                   deps.map { |d| [d[:name], d[:via]] }
    end
  end

  def test_gemfile_dependencies_ignore_directives
    with_tmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gemspec
        gem "billing"
        gem "rails", "~> 7.1"
        gem "local", path: "../local"
      RUBY
      deps = CCE::Workspace::Dependencies.extract(dir)
      assert_equal [%w[billing gemfile], %w[rails gemfile], %w[local gemfile]],
                   deps.map { |d| [d[:name], d[:via]] }
    end
  end

  def test_package_json_dependency_sections
    with_tmpdir do |dir|
      File.write(File.join(dir, "package.json"), JSON.generate(
        name: "web",
        dependencies: { "app" => "1.0.0" },
        devDependencies: { "jest" => "^29" },
        peerDependencies: { "react" => "^18" }
      ))
      deps = CCE::Workspace::Dependencies.extract(dir)
      assert_equal %w[app jest react], deps.map { |d| d[:name] }
      assert(deps.all? { |d| d[:via] == "package.json" })
    end
  end

  def test_malformed_package_json_is_empty
    with_tmpdir do |dir|
      File.write(File.join(dir, "package.json"), "{ not json")
      assert_empty CCE::Workspace::Dependencies.extract(dir)
    end
  end

  def test_no_manifests_is_empty
    with_tmpdir { |dir| assert_empty CCE::Workspace::Dependencies.extract(dir) }
  end
end
