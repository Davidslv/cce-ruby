# WHY: `stats --workspace` is the operator's one-glance ecosystem view; it must sum
#      per-member metrics from each member's own store and surface the edges (§7).
# WHAT: Unit tests for CCE::Workspace::Stats.

require_relative "test_helper"

class WorkspaceStatsTest < Minitest::Test
  include TestSupport

  def test_per_member_and_totals_after_index
    with_workspace_fixture do |root|
      manifest = CCE::Workspace::Manifest.detect(root)
      manifest.write(root)
      CCE::Workspace::Indexer.index(root)

      data = CCE::Workspace::Stats.compute(root, manifest)
      assert_equal %w[app billing web], data[:members].map { |m| m[:name] }
      assert(data[:members].all? { |m| m[:indexed] })
      assert_equal data[:members].sum { |m| m[:chunks] }, data[:totals][:chunks]
      assert_equal data[:members].sum { |m| m[:files] }, data[:totals][:files]
      assert_equal [{ from: "app", to: "billing", via: "gemfile" }], data[:edges]
      billing = data[:members].find { |m| m[:name] == "billing" }
      assert billing[:by_kind].key?("module") || billing[:by_kind].values.sum.positive?
    end
  end

  def test_unindexed_members_report_zero
    with_workspace_fixture do |root|
      manifest = CCE::Workspace::Manifest.detect(root)
      manifest.write(root)
      data = CCE::Workspace::Stats.compute(root, manifest)
      assert(data[:members].none? { |m| m[:indexed] })
      assert_equal 0, data[:totals][:chunks]
    end
  end
end
