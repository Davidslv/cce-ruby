# WHY: `index` runs in one process; `search`/`stats` in a fresh one. The store
#      must round-trip everything needed to reconstruct retrieval (SPEC §7).
# WHAT: Pins persistence round-trip, idempotent re-index, and stats.
# RESPONSIBILITIES: Guard save/load of chunks, vectors, imports, and metadata.

require_relative "test_helper"

class StoreTest < Minitest::Test
  include TestSupport

  def sample_chunks
    CCE::Chunker.chunk_file("def a(user):\n    return user\n", "a.py")
  end

  def test_round_trip_chunks_and_vectors
    with_tmpdir do |dir|
      store_path = File.join(dir, "idx.db")
      emb = CCE::HashEmbedder.new
      chunks = sample_chunks
      recs = chunks.map { |c| { chunk: c, vector: emb.embed(c.content) } }

      CCE::Store.create(store_path) do |s|
        s.write(records: recs, file_imports: { "a.py" => [] }, embedder: "hash")
      end

      s2 = CCE::Store.open(store_path)
      loaded = s2.chunks
      assert_equal chunks.length, loaded.length
      assert_equal chunks.first.chunk_id, loaded.first.chunk_id
      assert_equal chunks.first.content, loaded.first.content
      v = s2.vectors[chunks.first.chunk_id]
      assert_equal 256, v.length
      assert_in_delta emb.embed(chunks.first.content).first, v.first, 1e-12
      assert_equal "hash", s2.embedder_name
      s2.close
    end
  end

  def test_idempotent_reindex
    with_tmpdir do |dir|
      store_path = File.join(dir, "idx.db")
      emb = CCE::HashEmbedder.new
      recs = sample_chunks.map { |c| { chunk: c, vector: emb.embed(c.content) } }
      2.times do
        CCE::Store.create(store_path) do |s|
          s.write(records: recs, file_imports: { "a.py" => [] }, embedder: "hash")
        end
      end
      s2 = CCE::Store.open(store_path)
      assert_equal recs.length, s2.chunks.length
      s2.close
    end
  end

  def test_file_imports_round_trip
    with_tmpdir do |dir|
      store_path = File.join(dir, "idx.db")
      emb = CCE::HashEmbedder.new
      recs = sample_chunks.map { |c| { chunk: c, vector: emb.embed(c.content) } }
      CCE::Store.create(store_path) do |s|
        s.write(records: recs, file_imports: { "a.py" => %w[os sys] }, embedder: "hash")
      end
      s2 = CCE::Store.open(store_path)
      assert_equal %w[os sys], s2.file_imports["a.py"]
      s2.close
    end
  end
end
