# WHY: The benchmark runner computes the headline metrics; its recall, token
#      savings, and percentile maths must be correct (SPEC §10).
# WHAT: Unit tests for the metric helpers plus a small end-to-end run over a
#       synthetic mini-repo (no network, writes to a temp report path).
# RESPONSIBILITIES: Guard percentile, hit detection, token savings, and report
#       generation.

require_relative "test_helper"

class BenchTest < Minitest::Test
  include TestSupport

  def test_percentile
    samples = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    assert_in_delta 5.5, CCE::Bench.percentile(samples, 50), 1e-9
    assert_in_delta 9.55, CCE::Bench.percentile(samples, 95), 1e-9
    assert_in_delta 0.0, CCE::Bench.percentile([], 50), 1e-9
  end

  def test_hit_detection
    results = [{ file_path: "lib/router.rb" }, { file_path: "lib/base.rb" }]
    assert CCE::Bench.hit?(results, ["router"])
    refute CCE::Bench.hit?(results, ["nonexistent"])
    assert CCE::Bench.hit?(results, [""]) # empty substring always hits
  end

  def test_token_saving
    with_tmpdir do |repo|
      File.write(File.join(repo, "big.rb"), "x" * 400) # ~100 whole-file tokens
      results = [{ file_path: "big.rb", token_count: 10 }]
      saving = CCE::Bench.token_saving(results, repo)
      assert_operator saving, :>, 0.5
      assert_in_delta(1.0 - 10.0 / 100.0, saving, 1e-9)
    end
  end

  def test_language_query_sets_cover_the_four_benchmarked_languages
    assert_equal %w[ruby rust typescript c], CCE::Bench::LANGUAGE_QUERIES.keys
    CCE::Bench::LANGUAGE_QUERIES.each_value { |qs| assert_equal 10, qs.length }
  end

  def test_end_to_end_mini_repo
    with_tmpdir do |repo|
      File.write(File.join(repo, "base.rb"), <<~RUBY)
        def create_app(config)
          { config: config }
        end
      RUBY
      File.write(File.join(repo, "router.rb"), <<~RUBY)
        def register_route(app, route)
          true
        end
      RUBY
      report = File.join(repo, "REPORT.md")
      queries = File.join(repo, "q.txt")
      File.write(queries, "application factory -> base\nregister route -> router\n")

      out = StringIO.new
      path = CCE::Bench.run(repo, store_path: File.join(repo, "b.db"),
                            queries_file: queries, lang: "ruby", out: out, repeats: 2,
                            report_path: report)
      assert_equal report, path
      md = File.read(report)
      assert_match(/# CCE Benchmarks/, md)
      assert_match(/Corpus language \| ruby/, md)
      assert_match(/Recall@5/, md)
      assert_match(/Mean token savings/, md)
    end
  end
end
