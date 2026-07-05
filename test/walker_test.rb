# WHY: Indexing must skip the right files (VCS dirs, vendored deps, binaries,
#      oversized/non-UTF-8 files) or the corpus is polluted (SPEC §7.1).
# WHAT: Pins the ignore rules and file-walking behaviour.
# RESPONSIBILITIES: Guard directory/file exclusion and UTF-8/size limits.

require_relative "test_helper"

class WalkerTest < Minitest::Test
  include TestSupport

  def test_ignores_dot_and_vendor_dirs
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".git"))
      FileUtils.mkdir_p(File.join(dir, "node_modules"))
      FileUtils.mkdir_p(File.join(dir, ".cce"))
      FileUtils.mkdir_p(File.join(dir, "__pycache__"))
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, ".git", "config"), "x")
      File.write(File.join(dir, "node_modules", "a.js"), "x")
      File.write(File.join(dir, ".cce", "index.db"), "x")
      File.write(File.join(dir, "__pycache__", "a.py"), "x")
      File.write(File.join(dir, "src", "keep.py"), "def a():\n    return 1\n")
      File.write(File.join(dir, "top.py"), "def b():\n    return 2\n")

      files = CCE::Walker.walk(dir).map { |f| f[:rel] }.sort
      assert_equal ["src/keep.py", "top.py"], files
    end
  end

  def test_skips_oversized_files
    with_tmpdir do |dir|
      big = File.join(dir, "big.py")
      File.write(big, "x" * (CCE::Config::MAX_FILE_BYTES + 10))
      File.write(File.join(dir, "small.py"), "def a():\n    return 1\n")
      files = CCE::Walker.walk(dir).map { |f| f[:rel] }
      assert_equal ["small.py"], files
    end
  end

  def test_skips_non_utf8_files
    with_tmpdir do |dir|
      File.binwrite(File.join(dir, "bin.dat"), "\xff\xfe\x00\x01".b)
      File.write(File.join(dir, "ok.py"), "def a():\n    return 1\n")
      files = CCE::Walker.walk(dir).map { |f| f[:rel] }
      assert_equal ["ok.py"], files
    end
  end

  def test_relative_paths_use_forward_slash
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "a", "b"))
      File.write(File.join(dir, "a", "b", "c.py"), "def a():\n    return 1\n")
      rel = CCE::Walker.walk(dir).map { |f| f[:rel] }
      assert_equal ["a/b/c.py"], rel
    end
  end
end
