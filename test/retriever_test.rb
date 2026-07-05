# WHY: The retriever fuses vector + BM25 via RRF, blends confidence, penalises
#      test/doc paths, and enforces diversity — the core ranking contract
#      (SPEC §6). Its anchors (RRF, intent) must reproduce exactly.
# WHAT: Pins intent classification, the RRF anchor, path penalty, diversity cap,
#       and graph expansion end-to-end on the fixture corpus.
# RESPONSIBILITIES: Guard the full hybrid pipeline against the spec.

require_relative "test_helper"

class RetrieverTest < Minitest::Test
  include TestSupport

  # Build a retriever over the fixture chunks with the hash embedder.
  def build_from_fixture
    with_fixture_chunks do |chunks|
      return CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new)
    end
  end

  def with_fixture_chunks
    with_tmpdir do |dir|
      write_fixture(dir)
      chunks = []
      %w[auth.py payments.py README.md].each do |f|
        content = File.read(File.join(dir, f))
        chunks.concat(CCE::Chunker.chunk_file(content, f))
      end
      imports = {
        "payments.py" => CCE::Chunker.extract_imports(File.read(File.join(dir, "payments.py")), "python")
      }
      yield chunks, imports
    end
  end

  def test_intent_code_lookup
    assert_equal :code_lookup, CCE::Retriever.classify_intent("where is the login function")
    assert_equal :code_lookup, CCE::Retriever.classify_intent("open app.py please")
    assert_equal :code_lookup, CCE::Retriever.classify_intent("class SessionManager")
    assert_equal :code_lookup, CCE::Retriever.classify_intent("where is hash_password")
    assert_equal :code_lookup, CCE::Retriever.classify_intent("where hash_password is defined")
  end

  def test_intent_general
    assert_equal :general, CCE::Retriever.classify_intent("hash password")
    assert_equal :general, CCE::Retriever.classify_intent("process payment amount")
  end

  def test_fts_weight
    assert_in_delta 1.5, CCE::Retriever.fts_weight(:code_lookup), 1e-12
    assert_in_delta 1.0, CCE::Retriever.fts_weight(:general), 1e-12
  end

  def test_rrf_anchor
    # id at vrank 0 and frank 2, fts_weight 1.0 -> 1/60 + 1/62 = 0.032796
    rrf = CCE::Retriever.rrf_value(0, 2, 1.0)
    assert_in_delta 0.032796, rrf, 1e-6
  end

  def test_rrf_missing_ranks
    assert_in_delta (1.0 / 60), CCE::Retriever.rrf_value(0, nil, 1.0), 1e-12
    assert_in_delta (1.0 / 62), CCE::Retriever.rrf_value(nil, 2, 1.0), 1e-12
    assert_in_delta 0.0, CCE::Retriever.rrf_value(nil, nil, 1.0), 1e-12
  end

  def test_search_returns_results_with_scores
    with_fixture_chunks do |chunks|
      r = CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new)
      results = r.search("hash password", top_k: 5, graph_enabled: false)
      refute_empty results
      assert results.all? { |x| x[:score].is_a?(Float) }
      assert_operator results.length, :<=, 5
    end
  end

  def test_q1_top1_is_hash_password
    with_fixture_chunks do |chunks|
      r = CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new)
      top = r.search("hash password", top_k: 5, graph_enabled: false).first
      assert_equal "auth.py", top[:file_path]
      assert top[:content].include?("def hash_password")
    end
  end

  def test_q2_top1_is_process_payment
    with_fixture_chunks do |chunks|
      r = CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new)
      top = r.search("process payment amount", top_k: 5, graph_enabled: false).first
      assert_equal "payments.py", top[:file_path]
      assert top[:content].include?("def process_payment")
    end
  end

  def test_q3_top1_from_auth
    with_fixture_chunks do |chunks|
      r = CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new)
      top = r.search("create session user", top_k: 5, graph_enabled: false).first
      assert_equal "auth.py", top[:file_path]
      assert(top[:content].include?("create_session") || top[:content].include?("SessionManager"))
    end
  end

  def test_path_penalty_applied_to_doc_paths
    # README.md contains no marker; craft a doc-path chunk to verify penalty.
    chunks = [
      CCE::Chunker.chunk_file("def alpha():\n    return 1\n", "src/a.py"),
      CCE::Chunker.chunk_file("def alpha():\n    return 1\n", "docs/a.py")
    ].flatten
    r = CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new)
    results = r.search("alpha", top_k: 5, graph_enabled: false)
    src = results.find { |x| x[:file_path] == "src/a.py" }
    doc = results.find { |x| x[:file_path] == "docs/a.py" }
    assert_operator src[:score], :>, doc[:score]
  end

  def test_diversity_cap
    # 5 functions in one file; cap keeps at most 3 from that file.
    body = (1..5).map { |i| "def f#{i}(alpha):\n    return alpha\n" }.join("\n")
    chunks = CCE::Chunker.chunk_file(body, "big.py")
    r = CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new)
    results = r.search("alpha", top_k: 10, graph_enabled: false)
    from_big = results.count { |x| x[:file_path] == "big.py" }
    assert_operator from_big, :<=, CCE::Config::MAX_CHUNKS_PER_FILE
  end

  def test_graph_expansion_appends_neighbor_chunks
    with_fixture_chunks do |chunks, imports|
      r = CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new, file_imports: imports)
      # Query that hits payments.py; expansion should be able to pull auth.py.
      base = r.search("process payment amount", top_k: 2, graph_enabled: false)
      expanded = r.search("process payment amount", top_k: 2, graph_enabled: true)
      assert_operator expanded.length, :>=, base.length
    end
  end

  def test_empty_query_returns_empty
    with_fixture_chunks do |chunks|
      r = CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new)
      assert_empty r.search("", top_k: 5, graph_enabled: false)
    end
  end
end
