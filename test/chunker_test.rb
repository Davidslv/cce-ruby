# WHY: Chunking is where source becomes retrievable units; its node selection,
#      byte spans, import extraction, and deterministic IDs must match the spec
#      exactly or the conformance gate fails.
# WHAT: Pins SPEC §4.2 (tree-sitter chunking + fallback), §4.3 (chunk id),
#       §4.4 (token count), and the §8.1 fixture structural counts.
# RESPONSIBILITIES: Guard chunk extraction, fallback, imports, ids, token counts.

require_relative "test_helper"
require "digest"

class ChunkerTest < Minitest::Test
  include TestSupport

  AUTH_PY = <<~PY
    import hashlib

    def hash_password(password):
        return hashlib.sha256(password.encode()).hexdigest()

    def verify_password(password, digest):
        return hash_password(password) == digest

    class SessionManager:
        def create_session(self, user_id):
            return {"user": user_id}
  PY

  PAYMENTS_PY = <<~PY
    from auth import verify_password

    def process_payment(amount, currency):
        return {"amount": amount, "currency": currency, "status": "ok"}

    def refund_payment(payment_id):
        return {"payment_id": payment_id, "status": "refunded"}
  PY

  def chunk(content, path)
    CCE::Chunker.chunk_file(content, path)
  end

  def test_auth_py_yields_four_chunks
    chunks = chunk(AUTH_PY, "auth.py")
    names = chunks.map { |c| c.content[/\b(?:def|class)\s+(\w+)/, 1] }
    assert_equal 4, chunks.length
    assert_equal %w[hash_password verify_password SessionManager create_session].sort, names.sort
  end

  def test_auth_py_chunk_types
    chunks = chunk(AUTH_PY, "auth.py")
    by_name = chunks.to_h { |c| [c.content[/\b(?:def|class)\s+(\w+)/, 1], c] }
    assert_equal "function", by_name["hash_password"].chunk_type
    assert_equal "class", by_name["SessionManager"].chunk_type
    assert_equal "function", by_name["create_session"].chunk_type
    assert_equal "python", by_name["hash_password"].language
  end

  def test_hash_password_line_span
    chunks = chunk(AUTH_PY, "auth.py")
    hp = chunks.find { |c| c.content.include?("def hash_password") }
    assert_equal 3, hp.start_line
    assert_equal 4, hp.end_line
  end

  def test_class_and_method_overlap
    chunks = chunk(AUTH_PY, "auth.py")
    cls = chunks.find { |c| c.chunk_type == "class" }
    meth = chunks.find { |c| c.content.include?("def create_session") }
    assert cls.content.include?("def create_session"), "class chunk spans the whole class"
    assert meth.start_line >= cls.start_line
  end

  def test_payments_py_two_chunks
    chunks = chunk(PAYMENTS_PY, "payments.py")
    assert_equal 2, chunks.length
    assert_equal %w[process_payment refund_payment].sort,
                 chunks.map { |c| c.content[/def (\w+)/, 1] }.sort
  end

  def test_readme_fallback_module_chunk
    md = "# Demo\nPayment and authentication utilities.\n"
    chunks = chunk(md, "README.md")
    assert_equal 1, chunks.length
    c = chunks.first
    assert_equal "module", c.chunk_type
    assert_equal 1, c.start_line
    assert_equal 3, c.end_line # 3 lines incl trailing newline's line
    assert_equal "plaintext", c.language
    assert_equal md, c.content
  end

  def test_empty_python_file_falls_back
    chunks = chunk("x = 1\n", "mod.py")
    assert_equal 1, chunks.length
    assert_equal "module", chunks.first.chunk_type
    assert_equal "python", chunks.first.language
  end

  def test_python_imports
    imports = CCE::Chunker.extract_imports("import os.path\nfrom pkg.sub import x\nimport sys\n", "mod.py")
    assert_equal %w[os pkg sys], imports
  end

  def test_javascript_chunks_and_imports
    js = <<~JS
      import React from "react";
      import { thing } from "./auth";

      function greet(name) { return "hi " + name; }

      class Widget {
        render() { return 1; }
      }
    JS
    chunks = chunk(js, "app.js")
    types = chunks.map(&:chunk_type)
    assert_includes types, "function"
    assert_includes types, "class"
    imports = CCE::Chunker.extract_imports(js, "app.js")
    assert_equal %w[react auth], imports
  end

  def test_import_extraction_never_crashes
    assert_equal [], CCE::Chunker.extract_imports("!!!not valid$$$", "broken.py")
    assert_equal [], CCE::Chunker.extract_imports("anything", "notes.md")
  end

  def test_chunk_id_is_deterministic_and_matches_spec
    c = chunk(PAYMENTS_PY, "payments.py").find { |x| x.content.include?("process_payment") }
    prefix = c.content.b[0, 100]
    id_input = "payments.py:#{c.start_line}:#{c.end_line}:".b + prefix
    expected = Digest::SHA256.hexdigest(id_input)[0, 16]
    assert_equal expected, c.chunk_id
    assert_equal 16, c.chunk_id.length
  end

  def test_token_count
    c = chunk(PAYMENTS_PY, "payments.py").first
    assert_equal [1, c.content.bytesize / 4].max, c.token_count
    # min 1 rule
    tiny = CCE::Chunker.token_count("ab")
    assert_equal 1, tiny
  end
end
