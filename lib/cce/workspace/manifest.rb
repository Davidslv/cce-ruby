# WHY: A workspace is described by a reviewable, hand-editable manifest at the
#      root (SPEC-V2.2 §2). Generation must be deterministic (byte-identical across
#      machines/implementations) and loading must honour a hand-written file as-is.
# WHAT: The Manifest value object plus deterministic YAML read/write.
# RESPONSIBILITIES:
#   - Build a Manifest by detection, or load one from `<root>/.cce/workspace.yml`.
#   - Emit the exact §2 YAML shape (members sorted by path, stable key order).
#   - Write to disk, refusing to overwrite unless forced.
#   - Deliberately NOT own detection rules (Detector) or edges (Graph).

require "yaml"
require_relative "detector"

module CCE
  module Workspace
    class Manifest
      attr_reader :version, :name, :members

      def initialize(version:, name:, members:)
        @version = version
        @name = name
        @members = members
      end

      # Build a manifest by detecting members under `root`.
      def self.detect(root)
        root = File.expand_path(root)
        new(version: MANIFEST_VERSION, name: File.basename(root),
            members: Detector.detect(root))
      end

      # Absolute path to a root's manifest file.
      def self.path_for(root)
        File.join(Workspace.cce_dir(root), WORKSPACE_FILE)
      end

      def self.exist?(root)
        File.file?(path_for(root))
      end

      # Load a manifest from `<root>/.cce/workspace.yml`. A hand-written manifest is
      # honoured as-is: member order is preserved, not re-sorted.
      def self.load(root)
        path = path_for(root)
        raise Error, "no workspace.yml at #{path} (run `cce workspace init`)" unless File.file?(path)

        data = YAML.safe_load(File.read(path)) || {}
        members = Array(data["members"]).map do |m|
          Member.new(name: m["name"], path: m["path"], type: m["type"], package: m["package"])
        end
        new(version: data["version"] || MANIFEST_VERSION,
            name: data["name"] || File.basename(File.expand_path(root)),
            members: members)
      end

      # Deterministic §2 YAML. Members are emitted in the order held (detection
      # already sorts by path); a loaded, edited manifest round-trips its order.
      def to_yaml
        lines = []
        lines << "version: #{@version}"
        lines << "name: #{scalar(@name)}"
        if @members.empty?
          lines << "members: []"
        else
          lines << "members:"
          @members.each do |m|
            lines << "  - name: #{scalar(m.name)}"
            lines << "    path: #{scalar(m.path)}"
            lines << "    type: #{scalar(m.type)}"
            lines << "    package: #{scalar(m.package)}"
          end
        end
        lines.join("\n") + "\n"
      end

      # Write the manifest to `<root>/.cce/workspace.yml`.
      # @param force [Boolean] overwrite an existing manifest when true
      # @return [String] the path written
      def write(root, force: false)
        path = self.class.path_for(root)
        if File.exist?(path) && !force
          raise Error, "#{path} already exists (use --force to overwrite)"
        end

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, to_yaml)
        path
      end

      private

      # A plain scalar for simple tokens; JSON-style double-quoted otherwise. Keeps
      # neutral member/type/package names unquoted while staying safe for any value.
      def scalar(value)
        s = value.to_s
        s.match?(%r{\A[A-Za-z0-9][A-Za-z0-9_\-./]*\z}) ? s : s.inspect
      end
    end
  end
end
