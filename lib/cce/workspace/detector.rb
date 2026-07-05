# WHY: A workspace's members must be discovered mechanically and reproducibly so
#      the generated manifest is reviewable and identical across machines and
#      implementations (SPEC-V2.2 §3). Detection is the entry point to everything
#      else — get the members wrong and every downstream step is wrong.
# WHAT: Marker-based member auto-detection over a directory tree.
# RESPONSIBILITIES:
#   - Walk the tree with the standard ignore rules (SPEC §7.1) collecting members.
#   - Classify each member's type by the §3 marker precedence (gemspec → Rails →
#     package.json) and derive its dependency `package` name.
#   - Enforce "members do not nest" and the degenerate single-repo root case.
#   - Assign deterministic member ids (basename, collision-suffixed in path order).
#   - Deliberately NOT read manifests for edges (Dependencies) or write files.

require "json"
require_relative "../walker"

module CCE
  module Workspace
    # A detected/loaded member. `path` is workspace-root-relative with "/" separators.
    Member = Struct.new(:name, :path, :type, :package, keyword_init: true)

    module Detector
      module_function

      # Detect all members under `root`.
      # @return [Array<Member>] sorted by path, ids collision-suffixed deterministically.
      def detect(root)
        root = File.expand_path(root)
        raw = []
        collect(root, root, raw)
        # Degenerate single-repo: the root itself is a member with no sub-members.
        if raw.empty? && (type = classify(root))
          raw << { dir: root, type: type }
        end
        finalize(root, raw)
      end

      # Recursively collect member directories. Once a directory is a member we do
      # NOT descend into it (members do not nest). The root is never itself added
      # here; it only becomes the sole member via the degenerate case above.
      def collect(root, dir, out)
        if dir != root && (type = classify(dir))
          out << { dir: dir, type: type }
          return
        end
        child_dirs(dir).each { |child| collect(root, child, out) }
      end

      # Immediate subdirectories that are not excluded by the standard ignore rules.
      def child_dirs(dir)
        Dir.children(dir)
           .select { |name| File.directory?(File.join(dir, name)) && !Walker.skip_dir?(name) }
           .sort
           .map { |name| File.join(dir, name) }
      rescue SystemCallError
        []
      end

      # The member type for a directory, or nil if it has no marker (§3).
      def classify(dir)
        return ruby_type(dir) unless gemspecs(dir).empty?
        return "rails-app" if rails_app?(dir)
        return js_type(dir) if File.file?(File.join(dir, "package.json"))

        nil
      end

      def gemspecs(dir)
        Dir.glob(File.join(dir, "*.gemspec")).sort
      end

      # A gemspec dir is a ruby-engine if it also looks like a Rails engine, else
      # a plain ruby-gem (§3, rule 1).
      def ruby_type(dir)
        engine = File.directory?(File.join(dir, "app")) ||
                 File.file?(File.join(dir, "config", "routes.rb")) ||
                 !Dir.glob(File.join(dir, "lib", "**", "engine.rb")).empty?
        engine ? "ruby-engine" : "ruby-gem"
      end

      def rails_app?(dir)
        File.file?(File.join(dir, "Gemfile")) &&
          File.file?(File.join(dir, "config", "application.rb"))
      end

      def js_type(dir)
        File.file?(File.join(dir, "tsconfig.json")) ? "typescript" : "javascript"
      end

      # Turn raw {dir, type} hits into ordered, uniquely-named Members (§3).
      def finalize(root, raw)
        sorted = raw
                 .map { |h| { dir: h[:dir], type: h[:type], path: relative(root, h[:dir]) } }
                 .sort_by { |h| h[:path] }
        seen = Hash.new(0)
        sorted.map do |h|
          base = File.basename(h[:path])
          seen[base] += 1
          name = seen[base] == 1 ? base : "#{base}-#{seen[base]}"
          Member.new(name: name, path: h[:path], type: h[:type],
                     package: package_name(h[:dir], h[:type], base))
        end
      end

      # The dependency name other members use to require/import this member (§3).
      def package_name(dir, type, basename)
        case type
        when "ruby-engine", "ruby-gem" then gem_package_name(dir) || basename
        when "typescript", "javascript" then json_package_name(dir) || basename
        else basename # rails-app: the directory basename
        end
      end

      # The gem name from a gemspec's `name =` line, else the gemspec filename stem.
      def gem_package_name(dir)
        gemspec = gemspecs(dir).first
        return nil unless gemspec

        content = File.read(gemspec)
        if (m = content.match(/^\s*\w+\.name\s*=\s*["']([^"']+)["']/))
          m[1]
        else
          File.basename(gemspec, ".gemspec")
        end
      rescue SystemCallError
        gemspec ? File.basename(gemspec, ".gemspec") : nil
      end

      # The "name" field from package.json, else nil (caller falls back to basename).
      def json_package_name(dir)
        data = JSON.parse(File.read(File.join(dir, "package.json")))
        name = data["name"]
        name.is_a?(String) && !name.empty? ? name : nil
      rescue StandardError
        nil
      end

      def relative(root, abs)
        return "" if abs == root

        abs.delete_prefix(root + File::SEPARATOR).tr(File::SEPARATOR, "/")
      end
    end
  end
end
