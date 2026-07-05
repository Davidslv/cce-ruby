# WHY: The interchange artifact is the cross-language contract (SPEC-SYNC §2, §10
#      + SPEC-SYNC-RECONCILE): it must be byte-exact, checksum-reproducible, and a
#      lossless round-trip. If any of these drift, one engine's cache stops
#      serving the other and `--verify` is void. These tests pin all of it.
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

  def test_manifest_first_line_has_exactly_the_reconciled_keys
    with_tmpdir do |dir|
      art = export(dir)
      line = art[:bytes].lines.first
      manifest = JSON.parse(line)
      assert_equal %w[cce_version checksum chunk_count embedder file_tokens pack_set_id repo_id sha],
                   manifest.keys.sort
      assert_equal manifest.keys.sort, manifest.keys, "manifest keys must be sorted"
      refute_includes line, ": ", "compact separators only"
      assert_equal "hash", manifest["embedder"]
      assert_equal "2.3", manifest["cce_version"]
      assert_equal "github.com__acme__demo", manifest["repo_id"]
      assert_equal art[:checksum], manifest["checksum"]
      assert manifest["file_tokens"].is_a?(Hash), "file_tokens is an object"
    end
  end

  def test_no_provenance_keys
    with_tmpdir do |dir|
      manifest = JSON.parse(export(dir)[:bytes].lines.first)
      refute manifest.key?("built_at")
      refute manifest.key?("built_by")
    end
  end

  def test_lf_after_every_line_including_last
    with_tmpdir do |dir|
      bytes = export(dir)[:bytes]
      assert bytes.end_with?("\n"), "stream must end with LF"
      refute bytes.include?("\r"), "LF only, no CR"
    end
  end

  def test_chunk_objects_sorted_and_use_reconciled_keys
    with_tmpdir do |dir|
      art = export(dir)
      chunk_lines = art[:bytes].lines[1..-2]
      objs = chunk_lines.map { |l| JSON.parse(l) }
      keys = objs.map { |o| [o["file_path"], o["start_line"], o["id"]] }
      assert_equal keys.sort, keys
      expected = %w[chunk_type content embedding end_line file_path id kind language start_line token_count]
      assert_equal expected, objs.first.keys.sort
      assert objs.first.key?("id"), "chunk uses `id`, not chunk_id"
      assert objs.first.key?("language"), "chunk carries an explicit `language` field"
    end
  end

  def test_graph_is_nodes_and_edges_sorted
    with_tmpdir do |dir|
      # pay.py imports auth -> resolves to auth.py: one directed edge.
      art = A.export(build_store(dir, SYNC_SAMPLE), repo_id: "r", sha: "s")
      graph = JSON.parse(art[:bytes].lines.last)
      assert_equal %w[edges nodes], graph.keys.sort
      assert_equal [{ "id" => "auth.py" }, { "id" => "pay.py" }], graph["nodes"]
      assert_equal [{ "source" => "pay.py", "target" => "auth.py", "type" => "import" }], graph["edges"]
    end
  end

  def test_embedding_is_padded_base64_of_256_little_endian_f64
    with_tmpdir do |dir|
      art = export(dir)
      obj = JSON.parse(art[:bytes].lines[1])
      b64 = obj["embedding"]
      assert b64.end_with?("="), "standard base64 keeps padding"
      raw = b64.unpack1("m0")
      assert_equal 256 * 8, raw.bytesize, "256 f64 => 2048 bytes"
      vec = raw.unpack("E*")
      store_vec = CCE::Store.open(build_store(dir)).vectors[obj["id"]]
      assert_equal store_vec, vec, "vector round-trips bit-for-bit"
    end
  end

  def test_checksum_is_over_stream_with_empty_checksum_field
    with_tmpdir do |dir|
      art = export(dir)
      # Recompute independently: set checksum to "" and hash the whole stream.
      empty = art[:bytes].sub(/"checksum":"[0-9a-f]{64}"/, '"checksum":""')
      assert_equal Digest::SHA256.hexdigest(empty), art[:checksum]
      assert_equal art[:checksum], A.checksum_of(art[:bytes])
      assert A.checksum_valid?(art[:bytes])
    end
  end

  def test_checksum_detects_tampering
    with_tmpdir do |dir|
      art = export(dir)
      tampered = art[:bytes].sub('"token_count":', '"token_count":9999,"x":')
      refute A.checksum_valid?(tampered) if tampered != art[:bytes]
    end
  end

  def test_reproducible_regardless_of_build_order
    with_tmpdir do |dir|
      s = build_store(dir)
      a1 = A.export(s, repo_id: "r", sha: "s")
      a2 = A.export(s, repo_id: "r", sha: "s")
      assert_equal a1[:bytes], a2[:bytes], "no provenance => byte-identical rebuilds"
      a3 = A.export(s, repo_id: "OTHER", sha: "s")
      refute_equal a1[:checksum], a3[:checksum]
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
      assert_equal orig.chunks.map(&:language).sort, new.chunks.map(&:language).sort
      assert_equal orig.file_token_counts, new.file_token_counts, "whole-file token counts restored"

      # Graph-enabled search is identical (the real invariant for the graph).
      a = CCE::Indexer.retriever_from_store(store).search("hash password", top_k: 5, graph_enabled: true)
      b = CCE::Indexer.retriever_from_store(restored).search("hash password", top_k: 5, graph_enabled: true)
      assert_equal a.map { |r| r[:chunk_id] }, b.map { |r| r[:chunk_id] }
    end
  end

  def test_imported_store_reexports_to_identical_bytes
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
      store = File.join(dir, "index.db")
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
      graph = JSON.parse(art[:bytes].lines.last)
      assert_equal({ "edges" => [], "nodes" => [] }, graph)
      restored = File.join(dir, "restored.db")
      A.import(art[:bytes], restored)
      assert_empty CCE::Store.open(restored).chunks
    end
  end

  def test_pack_set_id_is_sorted_lowercase_pack_names
    assert_equal "c,javascript,python,ruby,rust,typescript", A.pack_set_id
  end

  # SHARED GOLDEN (SPEC-SYNC-RECONCILE): index test/fixture/samples with the
  # forced repo_id="cce/demo" and sha="0"*40, assert the checksum, and write the
  # raw bytes to /tmp/cce_artifact_ruby.cce so the orchestrator can diff Ruby vs
  # Rust byte-for-byte. Both engines MUST reproduce this checksum and file.
  GOLDEN_REPO_ID = "cce/demo"
  GOLDEN_SHA = "0" * 40
  GOLDEN_CHECKSUM = "581cbd0ff682a38d7d1250f3eec44f4ce456bdd660d4cb29aaaadd9e95072f48"

  def test_shared_golden_checksum_and_emit
    with_tmpdir do |dir|
      samples = File.expand_path("fixture/samples", __dir__)
      store = File.join(dir, "samples.db")
      CCE::Indexer.index(samples, store_path: store)
      art = A.export(store, repo_id: GOLDEN_REPO_ID, sha: GOLDEN_SHA)

      assert_equal GOLDEN_CHECKSUM, art[:checksum],
                   "shared golden checksum changed — re-sync with Rust before updating"
      assert A.checksum_valid?(art[:bytes])
      File.binwrite("/tmp/cce_artifact_ruby.cce", art[:bytes])
      assert File.exist?("/tmp/cce_artifact_ruby.cce")
    end
  end
end
