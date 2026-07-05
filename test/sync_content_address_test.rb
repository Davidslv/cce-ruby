# WHY: The content address is how a cache is keyed and how any engine resolves
#      repo@sha to the same path (SPEC-SYNC §3). repo_id normalization must be
#      stable across the many origin url forms git accepts.
# WHAT: Unit tests for CCE::Sync::ContentAddress.

require_relative "test_helper"

class SyncContentAddressTest < Minitest::Test
  CA = CCE::Sync::ContentAddress

  def test_normalizes_scp_like_origin
    assert_equal "github.com__acme__billing", CA.normalize_repo_id("git@github.com:acme/billing.git")
  end

  def test_normalizes_https_origin
    assert_equal "github.com__acme__billing", CA.normalize_repo_id("https://github.com/acme/billing.git")
  end

  def test_normalizes_ssh_url_with_port_and_user
    assert_equal "host__org__repo", CA.normalize_repo_id("ssh://git@host:22/org/repo")
  end

  def test_lowercases_host_only
    assert_equal "github.com__Acme__Billing", CA.normalize_repo_id("https://GitHub.com/Acme/Billing.git")
  end

  def test_nested_group_path
    assert_equal "gitlab.com__group__sub__repo", CA.normalize_repo_id("https://gitlab.com/group/sub/repo.git")
  end

  def test_blank_origin_raises
    assert_raises(CCE::Sync::Error) { CA.normalize_repo_id("  ") }
  end

  def test_key_and_prefix
    assert_equal "hash/2.3/r/abc.cce", CA.key(repo_id: "r", sha: "abc")
    assert_equal "hash/2.3/r", CA.prefix(repo_id: "r")
  end
end
