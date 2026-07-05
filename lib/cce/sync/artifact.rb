# WHY: The Ruby store is SQLite and the Rust store is JSON, so a shared cache
#      cannot be either native store. The artifact is a canonical, deterministic
#      interchange format both engines export and import, specified byte-exactly
#      so the blob for repo@sha is identical across people and across both
#      engines and `--verify` works cross-language (SPEC-SYNC §2, §10).
# WHAT: Export a store -> canonical artifact bytes (+ checksum), import artifact
#       -> a fresh local store, and compute/verify the checksum.
# RESPONSIBILITIES:
#   - Serialize a newline-delimited stream: manifest line, one compact sorted-key
#     JSON object per chunk (sorted by file_path,start_line,chunk_id), graph line.
#   - Encode each 256-d embedding as base64 of 256 little-endian IEEE-754 f64
#     bytes (NOT decimals), so vectors are bit-identical regardless of float
#     formatting.
#   - checksum = lowercase-hex SHA-256 over the canonical bytes with the
#     provenance keys (checksum/built_at/built_by) omitted from the manifest.
#   - Import losslessly: recompute each chunk's language from its path, restore
#     the import graph, rebuild the store with the hash embedder.
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

      # A stable pack_set_id: the sorted language-pack names of the registry,
      # comma-joined. Both engines derive it from the same registry, so it is the
      # same string (part of the manifest identity + checksum).
      def pack_set_id(registry = CCE.registry)
        registry.all.map(&:name).sort.join(",")
      end

      # Read a store and produce the artifact for repo@sha.
      # @return [Hash] { bytes:, checksum:, manifest:, chunk_count: }
      def export(store_path, repo_id:, sha:, built_at: nil, built_by: DEFAULT_BUILT_BY, registry: CCE.registry)
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
        ensure
          store.close
        end

        build(chunks: chunks, vectors: vectors, imports: imports, repo_id: repo_id,
              sha: sha, built_at: built_at, built_by: built_by, registry: registry)
      end

      # Build the artifact from in-memory pieces (used by export and by tests).
      def build(chunks:, vectors:, imports:, repo_id:, sha:, built_at: nil,
                built_by: DEFAULT_BUILT_BY, registry: CCE.registry)
        sorted = chunks.sort_by { |c| [c.file_path, c.start_line, c.chunk_id] }
        chunk_lines = sorted.map { |c| compact(chunk_object(c, vectors[c.chunk_id])) }
        graph_line = compact(graph_object(imports))

        core = manifest_core(repo_id: repo_id, sha: sha, chunk_count: sorted.length, registry: registry)
        canonical = join_lines([compact(core)] + chunk_lines + [graph_line])
        checksum = Digest::SHA256.hexdigest(canonical)

        manifest = core.merge(
          "built_at" => built_at.to_s,
          "built_by" => built_by.to_s,
          "checksum" => checksum
        )
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

      # Recompute the checksum from artifact bytes (provenance keys omitted).
      # Re-serializes each parsed object canonically, so a non-canonical or
      # tampered stream is detected.
      def checksum_of(bytes)
        data = parse(bytes)
        core = data[:manifest].reject { |k, _| PROVENANCE_KEYS.include?(k) }
        chunk_lines = data[:chunks].map { |c| compact(c) }
        canonical = join_lines([compact(core)] + chunk_lines + [compact(data[:graph])])
        Digest::SHA256.hexdigest(canonical)
      end

      # True when the artifact's embedded checksum matches its content.
      def checksum_valid?(bytes)
        parse(bytes)[:manifest]["checksum"] == checksum_of(bytes)
      end

      # Import an artifact into a fresh store at `store_path`, losslessly.
      # Language is recomputed from each chunk's path (it is a pure function of
      # the path via the registry), so the artifact need not carry it.
      # @return [Hash] the parsed manifest
      def import(bytes, store_path, registry: CCE.registry)
        data = parse(bytes)
        records = data[:chunks].map do |c|
          language = CCE::Chunker.language_for(c["file_path"], registry: registry) || "plaintext"
          chunk = CCE::Chunk.new(
            chunk_id: c["id"], file_path: c["file_path"],
            start_line: c["start_line"], end_line: c["end_line"],
            chunk_type: c["chunk_type"], kind: c["kind"], language: language,
            content: c["content"], token_count: c["token_count"]
          )
          { chunk: chunk, vector: decode_embedding(c["embedding"]) }
        end

        imports = data[:graph].each_with_object({}) { |(fp, mods), h| h[fp] = Array(mods) }
        CCE::Store.create(store_path) do |s|
          s.write(records: records, file_imports: imports, embedder: SHAREABLE_EMBEDDER)
        end
        data[:manifest]
      end

      # ---- serialization helpers ----------------------------------------------

      # The deterministic identity fields that are checksummed (SPEC-SYNC §2).
      def manifest_core(repo_id:, sha:, chunk_count:, registry: CCE.registry)
        {
          "cce_version" => Sync.cce_version,
          "chunk_count" => chunk_count,
          "embedder" => SHAREABLE_EMBEDDER,
          "pack_set_id" => pack_set_id(registry),
          "repo_id" => repo_id,
          "sha" => sha
        }
      end

      # One chunk's interchange object (SPEC-SYNC §2). Key name is `id` per spec.
      def chunk_object(chunk, vector)
        {
          "chunk_type" => chunk.chunk_type,
          "content" => chunk.content,
          "embedding" => encode_embedding(vector),
          "end_line" => chunk.end_line,
          "file_path" => chunk.file_path,
          "id" => chunk.chunk_id,
          "kind" => chunk.kind,
          "start_line" => chunk.start_line,
          "token_count" => chunk.token_count
        }
      end

      # The import graph: file_path -> module names, only for files with imports
      # (a file with no imports contributes no edge and no store row).
      def graph_object(imports)
        imports.each_with_object({}) do |(fp, mods), h|
          list = Array(mods)
          h[fp] = list unless list.empty?
        end
      end

      # base64 of 256 little-endian IEEE-754 f64 values (SPEC-SYNC §2). `m0`
      # packs strict base64 with no line breaks (== Base64.strict_encode64) and
      # needs no non-default-gem dependency.
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

      # Join canonical lines into a UTF-8, LF-terminated stream.
      def join_lines(lines)
        lines.map { |l| "#{l}\n" }.join
      end
    end
  end
end
