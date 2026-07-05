# WHY: The interchange artifact is the cross-language contract (SPEC-SYNC §2, §10):
#      it must be byte-exact, checksum-stable across builders, and a lossless
#      round-trip. If any of these drift, one engine's cache stops serving the
#      other and `--verify` is void. These tests pin all of it.
# WHAT: Unit + golden tests for CCE::Sync::Artifact.

require_relative "test_helper"
require "json"

class SyncArtifactTest < Minitest::Test
  include TestSupport

  A = CCE::Sync::Artifact

  def build_store(dir, files = SYNC_SAMPLE)
    files.each { |rel, c| File.write(File.join(dir, rel), c) }
    store = File.join(dir, "index.db")
    CCE::Indexer.index(dir, store_path: store)
    store
  end

  def export(dir, **opts)
    A.export(build_store(dir), repo_id: "github.com__acme__demo", sha: "a" * 40, **opts)
  end

  def test_manifest_first_line_has_sorted_compact_keys
    with_tmpdir do |dir|
      art = export(dir)
      line = art[:bytes].lines.first
      manifest = JSON.parse(line)
      assert_equal manifest.keys.sort, manifest.keys, "manifest keys must be sorted"
      refute_includes line, ": ", "compact separators only"
      assert_equal "hash", manifest["embedder"]
      assert_equal "2.3", manifest["cce_version"]
      assert_equal "github.com__acme__demo", manifest["repo_id"]
      assert_equal art[:checksum], manifest["checksum"]
    end
  end

  def test_chunk_objects_sorted_and_use_spec_keys
    with_tmpdir do |dir|
      art = export(dir)
      chunk_lines = art[:bytes].lines[1..-2]
      objs = chunk_lines.map { |l| JSON.parse(l) }
      # sorted by (file_path, start_line, id)
      keys = objs.map { |o| [o["file_path"], o["start_line"], o["id"]] }
      assert_equal keys.sort, keys
      expected = %w[chunk_type content embedding end_line file_path id kind start_line token_count]
      assert_equal expected, objs.first.keys.sort
      assert objs.first.key?("id"), "chunk uses `id` (SPEC-SYNC §2), not chunk_id"
    end
  end

  def test_embedding_is_base64_of_256_little_endian_f64
    with_tmpdir do |dir|
      art = export(dir)
      obj = JSON.parse(art[:bytes].lines[1])
      raw = obj["embedding"].unpack1("m0")
      assert_equal 256 * 8, raw.bytesize, "256 f64 => 2048 bytes"
      vec = raw.unpack("E*")
      assert_equal 256, vec.length
      # round-trips through the store's own vectors bit-for-bit
      store_vec = CCE::Store.open(build_store(dir)).vectors[obj["id"]]
      assert_equal store_vec, vec
    end
  end

  def test_checksum_excludes_provenance_and_is_stable
    with_tmpdir do |dir|
      s = build_store(dir)
      a1 = A.export(s, repo_id: "r", sha: "s", built_at: "2020-01-01T00:00:00Z", built_by: "ci")
      a2 = A.export(s, repo_id: "r", sha: "s", built_at: "2099-12-31T23:59:59Z", built_by: "someone-else")
      assert_equal a1[:checksum], a2[:checksum], "built_at/built_by must not affect checksum"
      # but the identity fields DO matter
      a3 = A.export(s, repo_id: "OTHER", sha: "s")
      refute_equal a1[:checksum], a3[:checksum]
    end
  end

  def test_checksum_of_matches_embedded_and_detects_tampering
    with_tmpdir do |dir|
      art = export(dir)
      assert_equal art[:checksum], A.checksum_of(art[:bytes])
      assert A.checksum_valid?(art[:bytes])
      tampered = art[:bytes].sub('"token_count":', '"token_count":9999,"x":')
      refute A.checksum_valid?(tampered) if tampered != art[:bytes]
    end
  end

  def test_round_trip_is_lossless_and_search_identical
    with_tmpdir do |dir|
      src = File.join(dir, "src"); FileUtils.mkdir_p(src)
      store = build_store(src)
      art = A.export(store, repo_id: "r", sha: "s")

      restored = File.join(dir, "restored.db")
      A.import(art[:bytes], restored)

      orig = CCE::Store.open(store)
      new = CCE::Store.open(restored)
      assert_equal orig.chunks.map(&:chunk_id).sort, new.chunks.map(&:chunk_id).sort
      assert_equal orig.vectors, new.vectors, "vectors bit-identical"
      assert_equal orig.file_imports, new.file_imports
      assert_equal orig.chunks.map(&:language).sort, new.chunks.map(&:language).sort

      a = CCE::Indexer.retriever_from_store(store).search("hash password", top_k: 5)
      b = CCE::Indexer.retriever_from_store(restored).search("hash password", top_k: 5)
      assert_equal a.map { |r| r[:chunk_id] }, b.map { |r| r[:chunk_id] }
    end
  end

  def test_imported_store_reexports_to_identical_checksum
    with_tmpdir do |dir|
      store = build_store(dir)
      art = A.export(store, repo_id: "r", sha: "s")
      restored = File.join(dir, "restored.db")
      A.import(art[:bytes], restored)
      art2 = A.export(restored, repo_id: "r", sha: "s")
      assert_equal art[:checksum], art2[:checksum]
      assert_equal art[:bytes], art2[:bytes]
    end
  end

  def test_export_refuses_non_hash_embedder
    with_tmpdir do |dir|
      File.write(File.join(dir, "auth.py"), SYNC_SAMPLE["auth.py"])
      store = File.join(dir, "index.db")
      # Write a store tagged with a non-hash embedder name.
      emb = CCE::HashEmbedder.new
      recs = CCE::Chunker.chunk_file(SYNC_SAMPLE["auth.py"], "auth.py").map { |c| { chunk: c, vector: emb.embed(c.content) } }
      CCE::Store.create(store) { |s| s.write(records: recs, file_imports: {}, embedder: "ollama") }
      err = assert_raises(CCE::Sync::Error) { A.export(store, repo_id: "r", sha: "s") }
      assert_match(/only 'hash'/, err.message)
    end
  end

  def test_parse_rejects_malformed
    assert_raises(CCE::Sync::Error) { A.parse("only-one-line") }
  end

  def test_encode_embedding_dim_guard
    assert_raises(CCE::Sync::Error) { A.encode_embedding([0.0, 1.0]) }
    assert_raises(CCE::Sync::Error) { A.decode_embedding(["short".b].pack("m0")) }
  end

  def test_empty_store_exports_and_imports
    with_tmpdir do |dir|
      store = File.join(dir, "empty.db")
      CCE::Store.create(store) { |s| s.write(records: [], file_imports: {}, embedder: "hash") }
      art = A.export(store, repo_id: "r", sha: "s")
      assert_equal 0, art[:chunk_count]
      assert A.checksum_valid?(art[:bytes])
      restored = File.join(dir, "restored.db")
      A.import(art[:bytes], restored)
      assert_empty CCE::Store.open(restored).chunks
    end
  end

  def test_pack_set_id_is_sorted_pack_names
    assert_equal "c,javascript,python,ruby,rust,typescript", A.pack_set_id
  end

  # GOLDEN: pins the exact checksum for a fixed fixture@sha so the orchestrator
  # can diff it against the Rust engine (SPEC-SYNC §10). If the format changes
  # this MUST change deliberately and in lock-step with Rust.
  def test_golden_checksum_for_fixed_fixture
    with_tmpdir do |dir|
      store = build_store(dir, SYNC_SAMPLE)
      art = A.export(store, repo_id: "github.com__acme__demo", sha: "d" * 40)
      assert_equal 64, art[:checksum].length
      assert_match(/\A[0-9a-f]{64}\z/, art[:checksum])
      # Recorded golden value (Ruby engine). Cross-language diff target.
      assert_equal GOLDEN_CHECKSUM, art[:checksum],
                   "artifact checksum changed — update GOLDEN_CHECKSUM and re-sync with Rust"
    end
  end

  GOLDEN_CHECKSUM = "70b6fb9312df793f01b20c6644e2dec705e1bc2538c63ae33d709b25a2220c62"
end
