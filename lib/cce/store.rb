# WHY: Indexing and searching happen in separate processes, so the corpus must
#      live on disk in a form that fully reconstructs retrieval state (SPEC §7).
# WHAT: A SQLite-backed store persisting chunks, embedding vectors, import edges,
#       per-file whole-file token counts (DASHBOARD-SPEC §3), and metadata.
# RESPONSIBILITIES:
#   - Create/open an on-disk store and (re)write a full corpus idempotently.
#   - Load chunks (as Chunk structs), vectors, per-file imports, and file tokens.
#   - Report on-disk size for stats.
#   - Deliberately NOT own chunking, embedding, or ranking.

require "sqlite3"
require "fileutils"
require_relative "config"
require_relative "chunker"

module CCE
  class Store
    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS chunks (
        chunk_id   TEXT PRIMARY KEY,
        file_path  TEXT NOT NULL,
        start_line INTEGER NOT NULL,
        end_line   INTEGER NOT NULL,
        chunk_type TEXT NOT NULL,
        language   TEXT NOT NULL,
        content    TEXT NOT NULL,
        token_count INTEGER NOT NULL,
        embedding  BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS file_imports (
        file_path TEXT NOT NULL,
        module    TEXT NOT NULL,
        ord       INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS file_tokens (
        file_path   TEXT PRIMARY KEY,
        token_count INTEGER NOT NULL
      );
    SQL

    def self.create(path)
      FileUtils.mkdir_p(File.dirname(path))
      store = new(path)
      store.setup!
      if block_given?
        begin
          yield store
        ensure
          store.close
        end
      else
        store
      end
    end

    def self.open(path)
      raise Error, "no index found at #{path}" unless File.exist?(path)

      new(path)
    end

    class Error < StandardError; end

    def initialize(path)
      @path = path
      @db = SQLite3::Database.new(path)
      @db.busy_timeout = 5000
    end

    def setup!
      @db.execute_batch(SCHEMA)
      self
    end

    # Idempotent full write: replace the entire corpus. Chunk IDs are
    # deterministic, so re-indexing the same directory yields the same store.
    def write(records:, file_imports:, embedder:, file_tokens: {})
      @db.transaction do
        @db.execute("DELETE FROM chunks")
        @db.execute("DELETE FROM file_imports")
        @db.execute("DELETE FROM file_tokens")
        @db.execute("DELETE FROM meta")
        @db.execute("INSERT INTO meta (key, value) VALUES ('embedder', ?)", [embedder])
        @db.execute("INSERT INTO meta (key, value) VALUES ('spec_version', ?)", [Config::SPEC_VERSION])

        ins = @db.prepare(
          "INSERT OR REPLACE INTO chunks
           (chunk_id, file_path, start_line, end_line, chunk_type, language, content, token_count, embedding)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
        )
        records.each do |rec|
          c = rec[:chunk]
          blob = SQLite3::Blob.new(pack_vector(rec[:vector]))
          ins.execute(c.chunk_id, c.file_path, c.start_line, c.end_line,
                      c.chunk_type, c.language, c.content, c.token_count, blob)
        end
        ins.close

        imp = @db.prepare("INSERT INTO file_imports (file_path, module, ord) VALUES (?, ?, ?)")
        file_imports.each do |fp, mods|
          mods.each_with_index { |m, i| imp.execute(fp, m, i) }
        end
        imp.close

        tok = @db.prepare("INSERT OR REPLACE INTO file_tokens (file_path, token_count) VALUES (?, ?)")
        file_tokens.each { |fp, count| tok.execute(fp, count) }
        tok.close
      end
      self
    end

    # @return [Array<Chunk>]
    def chunks
      @db.execute(
        "SELECT chunk_id, file_path, start_line, end_line, chunk_type, language, content, token_count
         FROM chunks"
      ).map do |row|
        Chunk.new(
          chunk_id: row[0], file_path: row[1], start_line: row[2], end_line: row[3],
          chunk_type: row[4], language: row[5], content: force_utf8(row[6]), token_count: row[7]
        )
      end
    end

    # @return [Hash{String=>Array<Float>}] chunk_id => vector
    def vectors
      map = {}
      @db.execute("SELECT chunk_id, embedding FROM chunks") do |row|
        map[row[0]] = unpack_vector(row[1])
      end
      map
    end

    # @return [Hash{String=>Array<String>}] file_path => module names in order
    def file_imports
      map = Hash.new { |h, k| h[k] = [] }
      @db.execute("SELECT file_path, module, ord FROM file_imports ORDER BY file_path, ord") do |row|
        map[row[0]] << row[1]
      end
      map
    end

    # @return [Hash{String=>Integer}] file_path => whole-file token count (SPEC §3)
    def file_token_counts
      map = {}
      @db.execute("SELECT file_path, token_count FROM file_tokens") do |row|
        map[row[0]] = row[1]
      end
      map
    end

    def embedder_name
      row = @db.get_first_row("SELECT value FROM meta WHERE key = 'embedder'")
      row ? row[0] : "hash"
    end

    def size_bytes
      File.exist?(@path) ? File.size(@path) : 0
    end

    def close
      @db.close if @db && !@db.closed?
    end

    private

    def pack_vector(vec)
      vec.pack("E*") # little-endian IEEE-754 doubles for portability
    end

    def unpack_vector(blob)
      str = blob.is_a?(String) ? blob : blob.to_s
      str.b.unpack("E*")
    end

    def force_utf8(str)
      str.dup.force_encoding(Encoding::UTF_8)
    end
  end
end
