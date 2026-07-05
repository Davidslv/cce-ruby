# WHY: Federated search is DEFINED to equal one §6 retrieval over the union of the
#      in-scope members' chunks (§6). This is the correctness anchor: the federated
#      result must equal a plain Retriever built over the same concatenated chunks,
#      scoping must be exact (with a clear error on unknown names), and a cross-member
#      edge must let a top result in one member hop into another (§8).
# WHAT: Integration tests for Federation + FederatedRetriever over the fixture.

require_relative "test_helper"

class WorkspaceFederationTest < Minitest::Test
  include TestSupport

  # Index the fixture once per test and yield (root, manifest).
  def with_indexed_workspace
    with_workspace_fixture do |root|
      manifest = CCE::Workspace::Manifest.detect(root)
      manifest.write(root)
      CCE::Workspace::Indexer.index(root)
      yield root, manifest
    end
  end

  def federated(root, manifest, packages)
    members = CCE::Workspace::Federation.scope_members(manifest, packages)
    loaded = CCE::Workspace::Federation.load_members(root, members)
    cross = CCE::Workspace::Graph.load(root)[:edges]
    CCE::Workspace::FederatedRetriever.new(members: loaded, cross_edges: cross)
  end

  # A plain Retriever built directly over the union of the two members' stored
  # chunks — the independent "union index" the federation must equal.
  def union_retriever(root, names)
    chunks = []
    vectors = {}
    imports = {}
    names.each do |name|
      store = CCE::Store.open(File.join(root, member_path(name), ".cce", "index.db"))
      begin
        store.chunks.each { |c| chunks << c }
        vectors.merge!(store.vectors)
        store.file_imports.each { |fp, mods| imports[fp] ||= mods }
      ensure
        store.close
      end
    end
    CCE::Retriever.new(chunks, embedder: CCE::HashEmbedder.new, vectors: vectors, file_imports: imports)
  end

  def member_path(name)
    { "app" => "app", "billing" => "engines/billing", "web" => "web" }.fetch(name)
  end

  def test_federation_equals_union_index
    with_indexed_workspace do |root, manifest|
      fed = federated(root, manifest, %w[app billing])
      union = union_retriever(root, %w[app billing])

      %w[charge amount process billing].each do |query|
        fed_results = fed.search(query, top_k: 10, graph_enabled: false)
        union_results = union.search(query, top_k: 10, graph_enabled: false)
        assert_equal union_results.map { |r| r[:chunk_id] }, fed_results.map { |r| r[:chunk_id] },
                     "chunk order diverged for #{query.inspect}"
        assert_equal union_results.map { |r| r[:score] }, fed_results.map { |r| r[:score] },
                     "scores diverged for #{query.inspect}"
      end
    end
  end

  def test_results_are_labelled_with_member
    with_indexed_workspace do |root, manifest|
      results = federated(root, manifest, %w[app billing]).search("charge", top_k: 10, graph_enabled: false)
      refute_empty results
      assert(results.all? { |r| %w[app billing].include?(r[:package]) })
      assert(results.all? { |r| r[:package] == r[:member] })
    end
  end

  def test_package_scoping_restricts_corpus
    with_indexed_workspace do |root, manifest|
      results = federated(root, manifest, %w[billing]).search("charge amount", top_k: 10, graph_enabled: false)
      refute_empty results
      assert_equal ["billing"], results.map { |r| r[:package] }.uniq
    end
  end

  def test_unknown_package_raises
    with_indexed_workspace do |_root, manifest|
      err = assert_raises(CCE::Workspace::Error) do
        CCE::Workspace::Federation.scope_members(manifest, %w[app nope])
      end
      assert_match(/unknown package/, err.message)
      assert_match(/nope/, err.message)
    end
  end

  def test_nil_scope_is_all_members
    with_indexed_workspace do |_root, manifest|
      members = CCE::Workspace::Federation.scope_members(manifest, nil)
      assert_equal %w[app billing web], members.map(&:name)
    end
  end

  def test_cross_member_graph_hop_into_billing
    with_indexed_workspace do |root, manifest|
      fed = federated(root, manifest, %w[app billing])
      # "process" matches only app's Charge#process, so billing is absent without
      # the graph; the app -> billing edge must then pull billing chunks in.
      without = fed.search("process", top_k: 1, graph_enabled: false)
      with = fed.search("process", top_k: 1, graph_enabled: true)

      assert_equal "app", without.first[:member]
      refute(without.any? { |r| r[:member] == "billing" })
      assert(with.any? { |r| r[:member] == "billing" },
             "expected a cross-member hop into billing")
      assert with.length > without.length
    end
  end

  def test_load_members_skips_unindexed_members
    with_workspace_fixture do |root|
      manifest = CCE::Workspace::Manifest.detect(root)
      manifest.write(root)
      # Index only app standalone; billing/web have no store yet.
      CCE::Indexer.index(File.join(root, "app"),
                         store_path: CCE::Workspace.member_store_path(root, manifest.members.first))
      loaded = CCE::Workspace::Federation.load_members(root, manifest.members)
      assert_equal ["app"], loaded.map { |m| m[:name] }
    end
  end
end
