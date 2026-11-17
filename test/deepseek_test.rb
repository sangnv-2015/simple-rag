require "test_helper"
require "stringio"
require "pp"

class DeepSeekTest < Minitest::Test
  MSGS = [{role: "user", content: "hi"}].freeze

  def sse(*events) = events.map { |e| "data: #{e}\n\n" }
  def test_inspect_and_pretty_inspect_never_show_key_or_host
    llm = Rag::DeepSeek.new(api_key: "sekret-123", base_url: "https://host.example/v1")
    objs = [llm, Rag::Ingest.new(llm: llm, embedder: Object.new, store: Object.new),
            Rag::Ask.new(llm: llm, embedder: Object.new, store: Object.new)]
    objs.each do |o|
      [o.inspect, o.pretty_inspect].each do |t|
        refute_includes t, "sekret-123"
        refute_includes t, "host.example"
      end
    end
  end

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
        err = assert_raises(Rag::DeepSeek::Error) { Rag::DeepSeek.new(api_key: "sk-test-1", base_url: url).chat(MSGS) }
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

  INVALID = "DeepSeek trả về dữ liệu không hợp lệ".freeze

  def run_chat(handler, key: "k", **opts, &blk)
    err = nil
    stderr = capture_stderr do
      FakeSSEServer.start(handler) do |url|
        @url = url
        err = assert_raises(Rag::DeepSeek::Error) { Rag::DeepSeek.new(api_key: key, base_url: url, **opts).chat(MSGS, &blk) }
      end
    end.last
    [err, stderr]
  end

  def test_http_error_body_is_redacted_of_key_and_url_before_truncation
    key = "sk-live-DISTINCT123"
    base = nil
    handler = ->(_) { [401, [%({"error":"bad #{key}","url":"#{base}","h":"Bearer #{key}"})]] }
    err = nil
    stderr = capture_stderr do
      FakeSSEServer.start(handler) do |url|
        base = url
        err = assert_raises(Rag::DeepSeek::Error) { Rag::DeepSeek.new(api_key: key, base_url: url).chat(MSGS) }
      end
    end.last
    refute_includes stderr, key
    refute_includes stderr, base
    refute_includes stderr, "127.0.0.1"
    assert_includes stderr, "401"
    refute_includes err.message, key
  end

  def test_http_error_body_truncated_to_300_chars
    _, stderr = run_chat(->(_) { [500, ["a" * 500]] })
    assert_includes stderr, "a" * 300
    refute_includes stderr, "a" * 301
  end

  def test_key_split_by_truncation_boundary_is_not_leaked
    key = "sk-live-BOUNDARY"
    _, stderr = run_chat(->(_) { [400, ["b" * 295 + key]] }, key: key)
    refute_includes stderr, "sk-li"
  end

  def test_error_event_in_stream_raises_after_partial_and_logs_redacted
    got = []
    err, stderr = run_chat(->(_) { [200, sse(delta("a"), '{"error":{"message":"boom sekret-k"}}', "[DONE]")] }, key: "sekret-k") { |d| got << d }
    assert_equal ["a"], got
    assert_equal INVALID, err.message
    assert_includes stderr, "boom"
    refute_includes stderr, "sekret-k"
  end

  def test_error_key_in_non_stream_200_raises_invalid
    err, = run_chat(->(_) { [200, ['{"error":{"message":"x"}}']] })
    assert_equal INVALID, err.message
  end

  def test_non_json_2xx_body_raises_invalid
    err, = run_chat(->(_) { [200, ["<html>nope</html>"]] })
    assert_equal INVALID, err.message
  end

  def test_wrong_shape_non_stream_bodies_raise_invalid
    ["null", "[]", '{"choices":["x"]}', '{"choices":[{"message":"x"}]}'].each do |body|
      err, = run_chat(->(_) { [200, [body]] })
      assert_equal INVALID, err.message, body
    end
  end

  def test_wrong_shape_stream_events_are_skipped
    chunks = sse("null", "[]", '{"choices":["x"]}', '{"choices":[{"delta":"x"}]}',
                 {choices: [{delta: {content: 5}}]}.to_json, delta("ok"), "[DONE]")
    FakeSSEServer.start(->(_) { [200, chunks] }) do |url|
      got = []
      Rag::DeepSeek.new(api_key: "k", base_url: url).chat(MSGS) { |d| got << d }
      assert_equal ["ok"], got
    end
  end

  def test_exception_from_caller_block_passes_through_unchanged
    FakeSSEServer.start(->(_) { [200, sse(delta("a"), delta("b"), "[DONE]")] }) do |url|
      e = assert_raises(IOError) do
        Rag::DeepSeek.new(api_key: "k", base_url: url).chat(MSGS) { |_| raise IOError, "closed" }
      end
      assert_equal "closed", e.message
    end
  end

  def test_read_timeout_maps_to_fixed_error
    err, = run_chat(->(_) { sleep 0.6; [200, ["{}"]] }, read_timeout: 0.2)
    assert_equal "Không kết nối được DeepSeek", err.message
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
