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
require "cce"

module TestSupport
  # Run a block inside a throwaway directory that is always cleaned up, so
  # persistence/index tests never touch the developer's working tree.
  def with_tmpdir
    Dir.mktmpdir("cce-test") do |dir|
      yield dir
    end
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
