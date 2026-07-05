# WHY: Cross-implementation equivalence is a hard acceptance gate; the
#      conformance harness must emit the exact structure and be deterministic
#      (SPEC §8).
# WHAT: Pins the fixture chunk set (7 chunks), the three query top-1 results,
#       the emitted JSON schema, and run-to-run determinism.
# RESPONSIBILITIES: Guard conformance.json structure and reproducibility.

require_relative "test_helper"
require "json"

class ConformanceTest < Minitest::Test
  include TestSupport

  def with_fixture
    with_tmpdir do |dir|
      write_fixture(dir)
      yield dir
    end
  end

  def test_seven_chunks_with_expected_types
    with_fixture do |dir|
      data = CCE::Conformance.run(dir)
      assert_equal 7, data[:chunks].length
      types = data[:chunks].map { |c| c[:chunk_type] }.tally
      assert_equal 5, types["function"] # 4 in auth+payments... actually 3 fn auth +2 payments = 5
      assert_equal 1, types["class"]
      assert_equal 1, types["module"]
    end
  end

  def test_chunks_sorted_by_file_start_id
    with_fixture do |dir|
      data = CCE::Conformance.run(dir)
      keys = data[:chunks].map { |c| [c[:file_path], c[:start_line], c[:chunk_id]] }
      assert_equal keys.sort, keys
    end
  end

  def test_query_top1s
    with_fixture do |dir|
      data = CCE::Conformance.run(dir)
      q = data[:queries].to_h { |x| [x[:query], x[:results]] }
      assert_equal "auth.py", q["hash password"].first[:file_path]
      assert_equal "payments.py", q["process payment amount"].first[:file_path]
      assert_equal "auth.py", q["create session user"].first[:file_path]
    end
  end

  def test_scores_are_fixed_six_decimals
    with_fixture do |dir|
      data = CCE::Conformance.run(dir)
      data[:queries].each do |query|
        query[:results].each do |r|
          assert_match(/\A\d+\.\d{6}\z/, r[:score])
        end
      end
    end
  end

  def test_impl_language_and_version
    with_fixture do |dir|
      data = CCE::Conformance.run(dir)
      assert_equal "ruby", data[:impl_language]
      assert_equal "2.0", data[:spec_version]
    end
  end

  def test_json_output_is_deterministic
    with_fixture do |dir|
      a = CCE::Conformance.to_json(dir)
      b = CCE::Conformance.to_json(dir)
      assert_equal a, b
      # parseable
      JSON.parse(a)
    end
  end

  def test_payments_imports_auth_edge_present_via_store
    with_fixture do |dir|
      store_path = File.join(dir, ".cce", "index.db")
      CCE::Indexer.index(dir, store_path: store_path, embedder: "hash")
      s = CCE::Store.open(store_path)
      assert_equal %w[auth], s.file_imports["payments.py"]
      s.close
    end
  end
end
