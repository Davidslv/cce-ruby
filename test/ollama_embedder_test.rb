# WHY: The optional Ollama backend must implement the same interface as the
#      hash embedder and fail clearly when the server is absent (SPEC §11).
# WHAT: Unit tests for input preparation + a live integration test that is
#       skipped unless CCE_OLLAMA_TEST is set (keeps the default suite hermetic).
# RESPONSIBILITIES: Guard truncation/empty handling and graceful unreachability.

require_relative "test_helper"

class OllamaEmbedderTest < Minitest::Test
  def test_reports_name
    assert_equal "ollama", CCE::OllamaEmbedder.new.name
  end

  def test_unreachable_server_raises_clear_error
    emb = CCE::OllamaEmbedder.new(host: "http://127.0.0.1:1") # nothing listens
    err = assert_raises(CCE::OllamaEmbedder::Unreachable) { emb.embed("hello") }
    assert_match(/Cannot reach Ollama/, err.message)
  end

  def test_empty_inputs_short_circuit_without_network
    emb = CCE::OllamaEmbedder.new(host: "http://127.0.0.1:1")
    # All-empty batch must not attempt a request.
    assert_equal [[]], emb.embed_batch([""])
  end

  def test_live_integration
    skip "set CCE_OLLAMA_TEST=1 to run the live Ollama integration test" unless ENV["CCE_OLLAMA_TEST"]

    emb = CCE::OllamaEmbedder.new
    v = emb.embed("hash the password")
    assert v.is_a?(Array)
    assert_operator v.length, :>, 0
  end
end
