require "test_helper"

class FakeStoreTest < Minitest::Test
  include StoreContract

  def make_store = FakeStore.new
end
