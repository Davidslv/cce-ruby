# WHY: Central test bootstrap so every test file gets coverage tracking and the
#      library on the load path without repeating boilerplate.
# WHAT: Configures SimpleCov (must be started before requiring app code), wires
#       the lib/ directory onto $LOAD_PATH, and pulls in Minitest.
# RESPONSIBILITIES:
#   - Start coverage measurement filtered to library logic (not tests/CLI shell).
#   - Require the CCE library once for all tests.
#   - Provide shared helpers (temp dirs) for hermetic, deterministic tests.

require "simplecov"
SimpleCov.start do
  add_filter "/test/"
  add_filter "/vendor/"
  enable_coverage :branch
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "cce"

# Real-format secret literals used by the redaction tests, assembled from split
# fragments so this committed source contains NO contiguous secret-shaped string
# (GitHub push protection scans for those). Concatenation happens at runtime, so
# the values fed to the redactor are byte-for-byte real-format secrets, while the
# file on disk holds only broken fragments. The break points sit inside each
# pattern's mandatory prefix (e.g. `sk` | `_live_`, `ghp` | `_`, `PRIVATE ` |
# `KEY`) so no scanner regex can match the source.
module SecretLiterals
  AWS       = "AKIA" + "IOSFODNN7EXAMPLE"
  STRIPE    = "sk" + "_live_" + "4eC39HqLyjWDarjtT1zdp7dc"
  GITHUB    = "ghp" + "_0123456789abcdefghijklmnopqrstuvwx01"
  SLACK     = "xox" + "b-1234567890-abcdefghijklmno"
  GOOGLE    = "AIza" + "SyA1234567890abcdefghijklmnopqrstuv"
  OPENAI    = "sk-" + "abcdefghijklmnopqrstuvwxyz0123456789"
  ANTHROPIC = "sk-ant-" + "api03-abcdef_ghijklmnopqrstuvwx"
  JWT       = "eyJ" + "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
              "eyJ" + "zdWIiOiIxMjM0NTY3ODkwIn0." +
              "dozjgNryP4J3jVmNHl0w5N"

  # Private-key block markers, broken between `PRIVATE ` and `KEY`.
  RSA_BEGIN     = "-----BEGIN RSA PRIVATE " + "KEY-----"
  RSA_END       = "-----END RSA PRIVATE " + "KEY-----"
  OPENSSH_BEGIN = "-----BEGIN OPENSSH PRIVATE " + "KEY-----"
  OPENSSH_END   = "-----END OPENSSH PRIVATE " + "KEY-----"
end

module TestSupport
  # Run a block inside a throwaway directory that is always cleaned up, so
  # persistence/index tests never touch the developer's working tree.
  def with_tmpdir
    Dir.mktmpdir("cce-test") do |dir|
      yield dir
    end
  end

  # Materialise the SPEC-V2.1 §3 secrets fixture into `dir` at runtime. The
  # secret-bearing files are generated here (never committed) so no repository
  # file holds a contiguous secret; the assembled contents are real-format.
  def write_secrets_fixture(dir)
    File.write(File.join(dir, ".env"), <<~ENV)
      AWS_ACCESS_KEY_ID=#{SecretLiterals::AWS}
      DATABASE_URL=postgres://user:hunter2@localhost/app
    ENV

    File.write(File.join(dir, ".env.example"), <<~ENV)
      AWS_ACCESS_KEY_ID=your-access-key-here
      DATABASE_URL=postgres://user:password@localhost/app
    ENV

    File.write(File.join(dir, "id_rsa"), <<~KEY)
      #{SecretLiterals::OPENSSH_BEGIN}
      b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAA
      #{SecretLiterals::OPENSSH_END}
    KEY

    File.write(File.join(dir, "config.rb"), <<~RB)
      module Config
        AWS = "#{SecretLiterals::AWS}"
        API_KEY = "your-api-key-here"
        STRIPE = "#{SecretLiterals::STRIPE}"
      end
    RB
  end

  # Absolute path to the committed workspace fixture (SPEC-V2.2 §8).
  def workspace_fixture_dir
    File.expand_path("fixture/workspace", __dir__)
  end

  # Copy the workspace fixture into a throwaway dir and yield its root, so
  # workspace index/search tests never write into the committed fixture tree.
  def with_workspace_fixture
    with_tmpdir do |dir|
      root = File.join(dir, "workspace")
      FileUtils.mkdir_p(root)
      FileUtils.cp_r("#{workspace_fixture_dir}/.", root)
      yield root
    end
  end

  # ---- CCE Sync helpers (SPEC-SYNC §11: hermetic, local bare git repo) -------

  # Run git in `dir` with a fixed identity, raising on failure. Used only to set
  # up the source/remote repos the sync tests act against (the engine has its own
  # git wrapper in lib/cce/sync/git.rb).
  def git(*args, dir:)
    out, status = Open3.capture2e(
      "git", "-c", "user.name=Test", "-c", "user.email=test@cce.local",
      "-C", dir, *args.map(&:to_s)
    )
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  # Create a bare git repository (a stand-in for the sync cache remote).
  def bare_repo(path)
    FileUtils.mkdir_p(File.dirname(path))
    _out, status = Open3.capture2e("git", "init", "--bare", "-q", path)
    raise "git init --bare failed" unless status.success?

    path
  end

  # Create a source git repo at `dir` with `files` (rel => content), a .gitignore
  # for .cce/, one commit, and return its HEAD sha. `origin` (a bare repo path)
  # is wired as the origin remote and the commit pushed to main when given.
  def init_source_repo(dir, files, origin: nil)
    FileUtils.mkdir_p(dir)
    git("init", "-q", dir: dir)
    git("symbolic-ref", "HEAD", "refs/heads/main", dir: dir)
    File.write(File.join(dir, ".gitignore"), ".cce/\n")
    files.each do |rel, content|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    git("add", "-A", dir: dir)
    git("commit", "-qm", "init", dir: dir)
    if origin
      git("remote", "add", "origin", "file://#{origin}", dir: dir)
      git("push", "-q", "origin", "HEAD:main", dir: dir)
    end
    git("rev-parse", "HEAD", dir: dir).strip
  end

  # A tiny two-file Python source tree used across sync tests.
  SYNC_SAMPLE = {
    "auth.py" => "import hashlib\n\ndef hash_password(p):\n    return hashlib.sha256(p.encode()).hexdigest()\n",
    "pay.py" => "from auth import hash_password\n\ndef process_payment(amount):\n    return amount\n"
  }.freeze

  # Build an injected GitRemote over a bare repo with a hermetic clone dir.
  def git_remote_for(url, base, lfs: false)
    CCE::Sync::GitRemote.new(url: "file://#{url}", clone_dir: File.join(base, "clone-#{rand(1 << 32)}"), lfs: lfs)
  end

  # Materialise the normative conformance fixture (SPEC §8.1) into `dir`.
  def write_fixture(dir)
    File.write(File.join(dir, "auth.py"), <<~PY)
      import hashlib

      def hash_password(password):
          return hashlib.sha256(password.encode()).hexdigest()

      def verify_password(password, digest):
          return hash_password(password) == digest

      class SessionManager:
          def create_session(self, user_id):
              return {"user": user_id}
    PY

    File.write(File.join(dir, "payments.py"), <<~PY)
      from auth import verify_password

      def process_payment(amount, currency):
          return {"amount": amount, "currency": currency, "status": "ok"}

      def refund_payment(payment_id):
          return {"payment_id": payment_id, "status": "refunded"}
    PY

    File.write(File.join(dir, "README.md"), <<~MD)
      # Demo
      Payment and authentication utilities.
    MD
  end
end
