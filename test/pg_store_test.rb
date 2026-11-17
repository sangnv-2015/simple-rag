require "test_helper"

class PgStoreTest < Minitest::Test
  include StoreContract

  def make_store
    store = Rag::Store.new(PgTestDb.url)
    store.migrate!
    store.send(:exec, "TRUNCATE documents RESTART IDENTITY CASCADE")
    store
  end
end
