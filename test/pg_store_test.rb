require "test_helper"

class PgStoreTest < Minitest::Test
  include StoreContract

  def make_store
    store = Rag::Store.new(PgTestDb.url)
    store.migrate!
    store.send(:exec, "TRUNCATE documents RESTART IDENTITY CASCADE")
    store
  end

  def test_recovers_after_connection_is_terminated
    store = make_store
    store.finish_document(store.start_document(filename: "a.pdf", sha256: "h"),
      pages: [Rag::Page.new(number: 1, raw_text: "r", markdown: nil, readable: true, fallback: false)], chunks: [])
    pid = store.send(:exec, "SELECT pg_backend_pid() AS pid").first["pid"]
    other = PG.connect(ENV.fetch("TEST_DATABASE_URL"))
    other.exec_params("SELECT pg_terminate_backend($1)", [pid])
    other.close
    assert_equal ["a.pdf"], store.documents.map(&:filename)
    page = store.pages("a.pdf").first
    assert_equal [true, false], [page.readable, page.fallback]
  end

  def test_basic_types_decode_before_migrate
    store = Rag::Store.new(PgTestDb.url)
    assert_equal [true, false], store.send(:exec, "SELECT true AS t, false AS f").first.values_at("t", "f")
  end
end
