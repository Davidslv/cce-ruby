# WHY: The Ruby store is SQLite and the Rust store is JSON, so a shared cache
#      cannot be either native store. The artifact is the single canonical,
#      deterministic interchange format both engines export and import, specified
#      byte-exactly (SPEC-SYNC §2, §10 + SPEC-SYNC-RECONCILE) so the blob for
#      repo@sha is identical across people and across both engines and `--verify`
#      works cross-language.
# WHAT: Export a store -> canonical artifact bytes (+ checksum), import artifact
#       -> a fresh local store, and compute/verify the checksum.
# RESPONSIBILITIES:
#   - Serialize a UTF-8, LF-after-every-line stream: manifest line, one compact
#     sorted-key JSON object per chunk (sorted by file_path,start_line,id), then a
#     graph line `{"edges":[…],"nodes":[…]}`.
#   - Encode each 256-d embedding as standard padded base64 of 256 little-endian
#     IEEE-754 f64 bytes (NOT decimals).
#   - checksum = lowercase-hex SHA-256 over the ENTIRE canonical stream built with
#     the manifest's `checksum` value set to "" (then the real hex is written in).
#   - Import losslessly: chunk fields incl. `language`, bit-exact vectors, the
#     import graph, and whole-file token counts.
#   - Deliberately NOT own git, the content address, or freshness policy.

require "json"
require "digest"
require_relative "../store"
require_relative "../chunker"

module CCE
  module Sync
    module Artifact
      # A 256-d embedding serializes to exactly 256 * 8 = 2048 raw bytes.
      EMBED_DIM = 256

      module_function

      # A stable pack_set_id: the sorted, comma-joined lowercase language-pack
      # names of the registry (part of the manifest identity + checksum).
      def pack_set_id(registry = CCE.registry)
        registry.all.map { |p| p.name.downcase }.sort.join(",")
      end

      # Read a store and produce the artifact for repo@sha.
      # @return [Hash] { bytes:, checksum:, manifest:, chunk_count: }
      def export(store_path, repo_id:, sha:, registry: CCE.registry)
        store = CCE::Store.open(store_path)
        begin
          embedder = store.embedder_name
          unless embedder == SHAREABLE_EMBEDDER
            raise Error, "index was built with the '#{embedder}' embedder; only " \
                         "'#{SHAREABLE_EMBEDDER}' indexes are shareable (SPEC-SYNC §1)"
          end
          chunks = store.chunks
          vectors = store.vectors
          imports = store.file_imports
          file_tokens = store.file_token_counts
        ensure
          store.close
        end

        build(chunks: chunks, vectors: vectors, imports: imports, file_tokens: file_tokens,
              repo_id: repo_id, sha: sha, registry: registry)
      end

      # Build the artifact from in-memory pieces (used by export and by tests).
      def build(chunks:, vectors:, imports:, file_tokens:, repo_id:, sha:, registry: CCE.registry)
        files = chunks.map(&:file_path).uniq
        sorted = chunks.sort_by { |c| [c.file_path, c.start_line, c.chunk_id] }
        chunk_lines = sorted.map { |c| compact(chunk_object(c, vectors[c.chunk_id])) }
        graph_line = compact(graph_object(imports, files))

        # Hash the ENTIRE stream with checksum:"" (SPEC-SYNC-RECONCILE), then write
        # the real hex into the checksum field of the emitted artifact.
        manifest0 = manifest_hash(repo_id: repo_id, sha: sha, chunk_count: sorted.length,
                                  file_tokens: file_tokens, checksum: "", registry: registry)
        stream0 = join_lines([compact(manifest0)] + chunk_lines + [graph_line])
        checksum = Digest::SHA256.hexdigest(stream0)

        manifest = manifest0.merge("checksum" => checksum)
        bytes = join_lines([compact(manifest)] + chunk_lines + [graph_line])
        { bytes: bytes, checksum: checksum, manifest: manifest, chunk_count: sorted.length }
      end

      # Parse a raw artifact into its manifest, chunk objects and graph. Every
      # object sits on one physical line (content newlines are JSON-escaped), so
      # splitting on "\n" is safe.
      def parse(bytes)
        lines = bytes.to_s.split("\n")
        raise Error, "malformed artifact: too few lines" if lines.length < 2

        manifest = JSON.parse(lines[0])
        graph = JSON.parse(lines[-1])
        chunk_objs = lines[1..-2].map { |l| JSON.parse(l) }
        { manifest: manifest, chunks: chunk_objs, graph: graph }
      end

      # Recompute the checksum from artifact bytes: set `checksum` to "" and hash
      # the whole re-serialized canonical stream. Re-canonicalizing every object
      # makes a non-canonical or tampered stream fail the check.
      def checksum_of(bytes)
        data = parse(bytes)
        manifest = data[:manifest].merge("checksum" => "")
        chunk_lines = data[:chunks].map { |c| compact(c) }
        stream = join_lines([compact(manifest)] + chunk_lines + [compact(data[:graph])])
        Digest::SHA256.hexdigest(stream)
      end

      # True when the artifact's embedded checksum matches its content.
      def checksum_valid?(bytes)
        parse(bytes)[:manifest]["checksum"] == checksum_of(bytes)
      end

      # Import an artifact into a fresh store at `store_path`, losslessly.
      # @return [Hash] the parsed manifest
      def import(bytes, store_path, registry: CCE.registry)
        data = parse(bytes)
        records = data[:chunks].map do |c|
          chunk = CCE::Chunk.new(
            chunk_id: c["id"], file_path: c["file_path"],
            start_line: c["start_line"], end_line: c["end_line"],
            chunk_type: c["chunk_type"], kind: c["kind"], language: c["language"],
            content: c["content"], token_count: c["token_count"]
          )
          { chunk: chunk, vector: decode_embedding(c["embedding"]) }
        end

        CCE::Store.create(store_path) do |s|
          s.write(records: records, file_imports: imports_from_graph(data[:graph]),
                  file_tokens: data[:manifest]["file_tokens"] || {}, embedder: SHAREABLE_EMBEDDER)
        end
        data[:manifest]
      end

      # ---- serialization helpers ----------------------------------------------

      # The full manifest object (SPEC-SYNC-RECONCILE): exactly these keys.
      def manifest_hash(repo_id:, sha:, chunk_count:, file_tokens:, checksum:, registry: CCE.registry)
        {
          "cce_version" => Sync.cce_version,
          "checksum" => checksum,
          "chunk_count" => chunk_count,
          "embedder" => SHAREABLE_EMBEDDER,
          "file_tokens" => file_tokens,
          "pack_set_id" => pack_set_id(registry),
          "repo_id" => repo_id,
          "sha" => sha
        }
      end

      # One chunk's interchange object (SPEC-SYNC-RECONCILE). Key name is `id`.
      def chunk_object(chunk, vector)
        {
          "chunk_type" => chunk.chunk_type,
          "content" => chunk.content,
          "embedding" => encode_embedding(vector),
          "end_line" => chunk.end_line,
          "file_path" => chunk.file_path,
          "id" => chunk.chunk_id,
          "kind" => chunk.kind,
          "language" => chunk.language,
          "start_line" => chunk.start_line,
          "token_count" => chunk.token_count
        }
      end

      # The import graph as `{"edges":[…],"nodes":[…]}`: nodes are the corpus
      # files (one `{"id": path}` each, sorted by id); edges are the resolved
      # file→file import relations `{"source","target","type":"import"}`, sorted
      # by (source, target, type). Resolution mirrors GraphStore (SPEC §6.7).
      def graph_object(imports, files)
        corpus = files.uniq.sort
        by_stem = {}
        corpus.each { |f| (by_stem[File.basename(f, File.extname(f))] ||= []) << f }

        edges = []
        imports.each do |from, mods|
          Array(mods).each do |mod|
            target = resolve_module(mod, by_stem, corpus)
            next if target.nil? || target == from

            edges << { "source" => from, "target" => target, "type" => "import" }
          end
        end
        edges = edges.uniq.sort_by { |e| [e["source"], e["target"], e["type"]] }
        { "edges" => edges, "nodes" => corpus.map { |f| { "id" => f } } }
      end

      # Reconstruct file_imports from the graph edges: each edge source→target
      # becomes an import of the target's stem, so the rebuilt store's GraphStore
      # reproduces the same adjacency (and identical graph-enabled search).
      def imports_from_graph(graph)
        out = Hash.new { |h, k| h[k] = [] }
        Array(graph["edges"]).each do |e|
          out[e["source"]] << File.basename(e["target"], File.extname(e["target"]))
        end
        out.transform_values(&:uniq)
      end

      def resolve_module(mod, by_stem, files)
        return by_stem[mod].min if by_stem.key?(mod) && !by_stem[mod].empty?

        files.select { |f| f.end_with?("#{mod}.py") || f.end_with?("#{mod}.js") }.min
      end

      # standard padded base64 (no newlines) of 256 little-endian IEEE-754 f64
      # values (SPEC-SYNC-RECONCILE). `m0` == RFC 4648 base64, padded, no breaks.
      def encode_embedding(vector)
        vec = Array(vector)
        raise Error, "embedding must be #{EMBED_DIM}-d, got #{vec.length}" unless vec.length == EMBED_DIM

        [vec.pack("E*")].pack("m0")
      end

      def decode_embedding(b64)
        raw = b64.to_s.unpack1("m0")
        vec = raw.unpack("E*")
        raise Error, "embedding decodes to #{vec.length} values, expected #{EMBED_DIM}" unless vec.length == EMBED_DIM

        vec
      end

      # Compact, sorted-key JSON (no insignificant whitespace) — the canonical
      # form for every object in the stream.
      def compact(obj)
        JSON.generate(deep_sort(obj))
      end

      # Recursively order hash keys so serialization is order-independent.
      def deep_sort(obj)
        case obj
        when Hash
          obj.map { |k, v| [k.to_s, deep_sort(v)] }.sort_by(&:first).to_h
        when Array
          obj.map { |e| deep_sort(e) }
        else
          obj
        end
      end

      # Join canonical lines into a UTF-8 stream with LF after every line
      # (including the last).
      def join_lines(lines)
        lines.map { |l| "#{l}\n" }.join
      end
    end
  end
end
