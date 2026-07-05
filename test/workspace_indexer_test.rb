# WHY: Federated storage's core promise is isolation: a member indexed inside a
#      workspace must be BYTE-IDENTICAL to indexing that member standalone, and the
#      graph must be written alongside (§4, §8). If this drifts, cross-language
#      per-member conformance is void.
# WHAT: Integration tests for CCE::Workspace::Indexer.

require_relative "test_helper"
require "digest"

class WorkspaceIndexerTest < Minitest::Test
  include TestSupport

  def test_indexes_each_member_into_its_own_store
    with_workspace_fixture do |root|
      CCE::Workspace::Manifest.detect(root).write(root)
      summary = CCE::Workspace::Indexer.index(root)

      names = summary[:members].map { |m| m[:name] }
      assert_equal %w[app billing web], names
      summary[:members].each do |m|
        assert File.exist?(m[:store_path]), "expected store at #{m[:store_path]}"
      end
      assert_equal summary[:totals][:chunks], summary[:members].sum { |m| m[:chunks] }
    end
  end

  def test_member_store_is_byte_identical_to_standalone
    with_workspace_fixture do |root|
      CCE::Workspace::Manifest.detect(root).write(root)
      CCE::Workspace::Indexer.index(root)

      %w[app engines/billing web].each do |rel|
        member_dir = File.join(root, rel)
        federated = File.join(member_dir, ".cce", "index.db")
        with_tmpdir do |tmp|
          standalone = File.join(tmp, "standalone.db")
          CCE::Indexer.index(member_dir, store_path: standalone)
          assert_equal Digest::SHA256.file(standalone).hexdigest,
                       Digest::SHA256.file(federated).hexdigest,
                       "member #{rel} store differs from standalone"
        end
      end
    end
  end

  def test_writes_graph_file
    with_workspace_fixture do |root|
      CCE::Workspace::Manifest.detect(root).write(root)
      summary = CCE::Workspace::Indexer.index(root)
      assert File.exist?(summary[:graph_path])
      assert_equal [{ from: "app", to: "billing", via: "gemfile" }], summary[:graph][:edges]
    end
  end

  def test_index_without_manifest_raises
    with_tmpdir do |root|
      err = assert_raises(CCE::Workspace::Error) { CCE::Workspace::Indexer.index(root) }
      assert_match(/workspace init/, err.message)
    end
  end
end
