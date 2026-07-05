# WHY: Import-graph expansion pulls in related files a pure ranking would miss;
#      its edge extraction and neighbor lookup must be correct (SPEC §6.7).
# WHAT: Pins edge resolution (module name -> corpus file) and neighbor lookup.
# RESPONSIBILITIES: Guard graph construction and undirected neighbor queries.

require_relative "test_helper"

class GraphStoreTest < Minitest::Test
  def build
    # payments.py imports auth (module) which resolves to auth.py
    file_imports = {
      "payments.py" => %w[auth],
      "auth.py" => %w[hashlib],
      "utils/helpers.py" => %w[payments]
    }
    files = %w[auth.py payments.py utils/helpers.py]
    CCE::GraphStore.new(file_imports, files)
  end

  def test_edge_resolution_by_stem
    g = build
    # payments -> auth resolves; hashlib does not resolve to a corpus file
    assert_includes g.neighbors("payments.py"), "auth.py"
  end

  def test_neighbors_are_undirected
    g = build
    # helpers imports payments; so payments has helpers as a neighbor too
    assert_includes g.neighbors("payments.py"), "utils/helpers.py"
    assert_includes g.neighbors("auth.py"), "payments.py"
  end

  def test_unknown_module_has_no_edge
    g = build
    refute_includes g.neighbors("auth.py"), "hashlib"
  end
end
