require "test_helper"

class EmbedderTest < Minitest::Test
  class FakePipe
    attr_reader :calls

    def initialize = @calls = []

    def call(texts)
      @calls << texts
      texts.map { |t| [t.size.to_f] }
    end
  end

  def test_passages_get_prefix_and_are_batched_in_order
    pipe = FakePipe.new
    texts = (0...70).map { |i| "t" * (i + 1) }
    vectors = Rag::Embedder.new(pipe: pipe).embed_passages(texts)
    assert_equal [32, 32, 6], pipe.calls.map(&:size)
    assert pipe.calls.flatten.all? { |t| t.start_with?("passage: ") }
    assert_equal 70, vectors.size
    assert_equal texts.map { |t| ("passage: " + t).size.to_f }, vectors.map(&:first)
  end

  def test_empty_list_does_not_call_pipe
    pipe = FakePipe.new
    assert_equal [], Rag::Embedder.new(pipe: pipe).embed_passages([])
    assert_empty pipe.calls
  end

  def test_query_gets_query_prefix_and_returns_one_vector
    pipe = FakePipe.new
    vec = Rag::Embedder.new(pipe: pipe).embed_query("Nghỉ phép?")
    assert_equal [["query: Nghỉ phép?"]], pipe.calls
    assert_equal ["query: Nghỉ phép?".size.to_f], vec
  end
end
