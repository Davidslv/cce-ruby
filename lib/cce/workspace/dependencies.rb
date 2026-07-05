# WHY: Cross-member relationships (Level 1) come from the dependency names a member
#      DECLARES in its manifests (SPEC-V2.2 §5). Reading them from the same manifests
#      a human reads keeps edges explainable and reproducible.
# WHAT: Declared-dependency extraction from `*.gemspec`, `Gemfile`, and `package.json`.
# RESPONSIBILITIES:
#   - gemspec: capture the first string arg of add[_runtime/_development]_dependency.
#   - Gemfile: capture the first string arg of each `gem "name"` (ignore options).
#   - package.json: the keys of dependencies/devDependencies/peerDependencies.
#   - Tag each with its source `via` (gemspec | gemfile | package.json).
#   - Deliberately NOT decide which names become edges (Graph does that).

require "json"

module CCE
  module Workspace
    module Dependencies
      # Line regex for gemspec dependency declarations (§5).
      GEMSPEC_DEP = /\.add(?:_runtime|_development)?_dependency\s*\(?\s*["']([^"']+)["']/.freeze
      # Line regex for a Gemfile `gem "name"` declaration (first string arg).
      GEMFILE_GEM = /^\s*gem\s+["']([^"']+)["']/.freeze
      PACKAGE_JSON_SECTIONS = %w[dependencies devDependencies peerDependencies].freeze

      module_function

      # All declared dependencies for a member directory, across whichever manifests
      # exist. @return [Array<Hash>] each { name:, via: } in read order.
      def extract(dir)
        deps = []
        deps.concat(from_gemspecs(dir))
        deps.concat(from_gemfile(dir))
        deps.concat(from_package_json(dir))
        deps
      end

      def from_gemspecs(dir)
        Dir.glob(File.join(dir, "*.gemspec")).sort.flat_map do |path|
          scan(path, GEMSPEC_DEP, "gemspec")
        end
      end

      def from_gemfile(dir)
        path = File.join(dir, "Gemfile")
        return [] unless File.file?(path)

        scan(path, GEMFILE_GEM, "gemfile")
      end

      def from_package_json(dir)
        path = File.join(dir, "package.json")
        return [] unless File.file?(path)

        data = JSON.parse(File.read(path))
        names = PACKAGE_JSON_SECTIONS.flat_map do |section|
          sec = data[section]
          sec.is_a?(Hash) ? sec.keys : []
        end
        names.map { |name| { name: name, via: "package.json" } }
      rescue StandardError
        []
      end

      # Scan a text manifest line-by-line, capturing group 1 of `pattern`.
      def scan(path, pattern, via)
        out = []
        File.foreach(path) do |line|
          m = line.match(pattern)
          out << { name: m[1], via: via } if m
        end
        out
      rescue SystemCallError
        []
      end
    end
  end
end
