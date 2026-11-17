require "test_helper"
require "stringio"

class DeepSeekTest < Minitest::Test
  MSGS = [{role: "user", content: "hi"}].freeze

  def sse(*events) = events.map { |e| "data: #{e}\n\n" }
  def delta(text) = {choices: [{delta: {content: text}}]}.to_json

  def test_non_stream_returns_content_and_sends_expected_request
    seen = nil
    FakeSSEServer.start(->(req) { seen = req; [200, [{choices: [{message: {content: "ok"}}]}.to_json]] }) do |url|
      c = Rag::DeepSeek.new(api_key: "k", base_url: url + "/", model: "m")
      assert_equal "ok", c.chat(MSGS)
    end
    assert_equal "/v1/chat/completions", seen.path
    assert_equal "Bearer k", seen.headers["authorization"]
    body = seen.json_body
    assert_equal({"enabled" => false}, body["reasoning"])
    refute body.key?("thinking")
    refute body.key?("stream")
    assert_equal "m", body["model"]
    assert_equal 0, body["temperature"]
    assert_equal [{"role" => "user", "content" => "hi"}], body["messages"]
  end

  def test_stream_yields_deltas_in_order_and_returns_concatenation
    seen = nil
    FakeSSEServer.start(->(req) { seen = req; [200, sse(delta("Xin "), delta("chào"), "[DONE]")] }) do |url|
      got = []
      out = Rag::DeepSeek.new(api_key: "k", base_url: url).chat(MSGS) { |d| got << d }
      assert_equal ["Xin ", "chào"], got
      assert_equal "Xin chào", out
    end
    assert_equal true, seen.json_body["stream"]
  end

  def test_stream_ignores_comments_empty_choices_null_content_and_reasoning
    chunks = [": keep-alive\n\n"] + sse('{"choices":[]}',
      {choices: [{delta: {content: nil}}]}.to_json,
      {choices: [{delta: {reasoning_content: "think"}}]}.to_json,
      delta(""), delta("a"), "[DONE]")
    FakeSSEServer.start(->(_) { [200, chunks] }) do |url|
      got = []
      out = Rag::DeepSeek.new(api_key: "k", base_url: url).chat(MSGS) { |d| got << d }
      assert_equal ["a"], got
      assert_equal "a", out
    end
  end

  def test_stream_json_line_split_across_tcp_writes_and_crlf
    line = "data: #{delta("Xin chào")}\r\n\r\n"
    cut = line.bytesize / 2
    chunks = [line.byteslice(0, cut), line.byteslice(cut..), "data: [DONE]\r\n\r\n"]
    FakeSSEServer.start(->(_) { [200, chunks] }) do |url|
      got = []
      Rag::DeepSeek.new(api_key: "k", base_url: url).chat(MSGS) { |d| got << d }
      assert_equal ["Xin chào"], got
    end
  end

  def test_stream_stops_at_done
    FakeSSEServer.start(->(_) { [200, sse(delta("a"), "[DONE]", delta("late"))] }) do |url|
      got = []
      Rag::DeepSeek.new(api_key: "k", base_url: url).chat(MSGS) { |d| got << d }
      assert_equal ["a"], got
    end
  end

  def test_http_error_message_has_status_but_not_key_or_body
    err = nil
    _, stderr = capture_stderr do
      FakeSSEServer.start(->(_) { [401, ["secret-key-echo"]] }) do |url|
        err = assert_raises(Rag::DeepSeek::Error) { Rag::DeepSeek.new(api_key: "k", base_url: url).chat(MSGS) }
      end
    end
    assert_equal "Không gọi được DeepSeek (HTTP 401)", err.message
    refute_includes err.message, "secret"
    assert_includes stderr, "secret-key-echo"
    assert_includes stderr, "401"
  end

  def test_connection_refused_raises_error
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
    url = "http://127.0.0.1:#{port}/v1"
    err = nil
    _, stderr = capture_stderr do
      err = assert_raises(Rag::DeepSeek::Error) { Rag::DeepSeek.new(api_key: "sekret", base_url: url).chat(MSGS) }
    end
    assert_equal "Không kết nối được DeepSeek", err.message
    [err.message, stderr].each do |s|
      refute_includes s, "127.0.0.1"
      refute_includes s, "sekret"
    end
  end

  def test_malformed_base_url_raises_fixed_error_without_leaking
    url = "http://secret host.example/v1"
    err = nil
    _, stderr = capture_stderr do
      err = assert_raises(Rag::DeepSeek::Error) { Rag::DeepSeek.new(api_key: "sekret", base_url: url).chat(MSGS) }
    end
    assert_equal "Không kết nối được DeepSeek", err.message
    [err.message, stderr].each do |s|
      refute_includes s, "secret host"
      refute_includes s, "example"
      refute_includes s, "sekret"
    end
  end

  def test_stream_cut_before_done_raises_after_yielding_partial
    FakeSSEServer.start(->(_) { [200, sse(delta("Xin "))] }) do |url|
      got = []
      err = assert_raises(Rag::DeepSeek::Error) do
        Rag::DeepSeek.new(api_key: "k", base_url: url).chat(MSGS) { |d| got << d }
      end
      assert_equal ["Xin "], got
      assert_equal "DeepSeek ngắt kết nối giữa chừng", err.message
    end
  end

  def test_blank_non_stream_content_returns_empty_string
    FakeSSEServer.start(->(_) { [200, [{choices: [{message: {content: nil}}]}.to_json]] }) do |url|
      assert_equal "", Rag::DeepSeek.new(api_key: "k", base_url: url).chat(MSGS)
    end
  end

  private

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    [nil, $stderr.string]
  ensure
    $stderr = old
  end
end
