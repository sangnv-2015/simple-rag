require "test_helper"
require "json"
require "puma"
require "puma/client"
require "rack/mock"
require_relative "../../web/app"

class FakeAsk
  attr_reader :calls

  # script: Proc(question, &on_delta) -> Answer; may raise.
  def initialize(&script)
    @script, @calls = script, []
  end

  def call(question, &on_delta)
    @calls << question
    @script.call(question, &on_delta)
  end
end

class AskRouteTest < Minitest::Test
  FRIENDLY = "Không thể trả lời lúc này. Vui lòng thử lại sau."

  def app_with(ask: nil, store: FakeStore.new)
    ask ||= FakeAsk.new { Rag::Answer.new("", false, []) }
    Class.new(Web) { set :ask, ask; set :store, store }
  end

  def get(app, path, host: "localhost:4567")
    Rack::MockRequest.new(app).get(path, "HTTP_HOST" => host)
  end

  def events(body)
    body.split("\n\n").map do |blk|
      name = blk[/\Aevent: (.+)$/, 1]
      data = blk[/^data: (.+)\z/, 1]
      [name, JSON.parse(data)]
    end
  end

  def done_store
    FakeStore.new.tap { |s| s.finish_document(s.start_document(filename: "a.pdf", sha256: "x"), pages: [], chunks: []) }
  end

  def test_index_shows_title_link_and_guidance_when_no_documents
    res = get(app_with, "/")
    assert_equal 200, res.status
    assert_includes res.body, "Hỏi đáp tài liệu"
    assert_includes res.body, 'href="/documents"'
    assert_includes res.body, "Chưa có tài liệu nào. Chạy lệnh nạp (docker compose run --rm app bin/ingest) hoặc tải file lên ở trang Tài liệu."
    assert_includes res.body, ">Tài liệu</a>"
    assert_match(%r{<button[^>]*>Hỏi</button>}, res.body)
  end

  def test_index_has_no_guidance_when_a_document_is_done
    res = get(app_with(store: done_store), "/")
    refute_includes res.body, "Chưa có tài liệu nào."
  end

  def test_ask_streams_deltas_then_done_with_sources
    src = Rag::Source.new(1, "a.docx", 3, "trích dẫn")
    ask = FakeAsk.new do |_q, &d|
      d.call("Xin "); d.call("chào [S1]")
      Rag::Answer.new("Xin chào [S1]", true, [src])
    end
    res = get(app_with(ask: ask), "/ask?q=hello")
    assert_includes res.content_type, "text/event-stream"
    assert_equal "no-cache", res.headers["Cache-Control"]
    assert_equal "no", res.headers["X-Accel-Buffering"]
    ev = events(res.body)
    assert_equal %w[delta delta done], ev.map(&:first)
    assert_equal ["Xin ", "chào [S1]"], ev[0, 2].map { |_, d| d["text"] }
    assert_equal true, ev[2][1]["found"]
    assert_equal({ "n" => 1, "filename" => "a.docx", "page" => 3, "quote" => "trích dẫn", "docx" => true }, ev[2][1]["sources"][0])
  end

  def test_not_found_after_streamed_text_still_reports_found_false
    ask = FakeAsk.new { |_q, &d| d.call("bịa"); Rag::Answer.new("bịa", false, []) }
    ev = events(get(app_with(ask: ask), "/ask?q=x").body)
    assert_equal %w[delta done], ev.map(&:first)
    assert_equal false, ev.last[1]["found"]
    assert_equal "", ev.last[1]["text"]
    assert_empty ev.last[1]["sources"]
  end

  def test_multiline_answer_with_script_tag_is_one_data_line
    text = "dòng 1\n</script><b>x</b>"
    ask = FakeAsk.new { |_q, &d| d.call(text); Rag::Answer.new(text, true, [Rag::Source.new(2, "B.PDF", 1, nil)]) }
    body = get(app_with(ask: ask), "/ask?q=x").body
    blocks = body.split("\n\n")
    assert_equal 2, blocks.size
    blocks.each { |b| assert_equal 2, b.lines.size, "event must be exactly event: + one data: line" }
    ev = events(body)
    assert_equal text, ev[0][1]["text"]
    assert_equal false, ev[1][1]["sources"][0]["docx"]
    assert_nil ev[1][1]["sources"][0]["quote"]
  end

  def test_blank_question_is_400_and_ask_not_called
    ask = FakeAsk.new { raise "must not be called" }
    app = app_with(ask: ask)
    assert_equal 400, get(app, "/ask?q=%20%20").status
    assert_equal 400, get(app, "/ask").status
    assert_empty ask.calls
  end

  def test_ask_error_gives_friendly_event_without_details
    [Rag::DeepSeek::Error.new("Không gọi được DeepSeek (HTTP 502)"), RuntimeError.new("boom")].each do |err|
      ask = FakeAsk.new { raise err }
      body = capture_stderr { get(app_with(ask: ask), "/ask?q=x").body }.first
      assert_equal [["error", { "message" => FRIENDLY }]], events(body)
      %w[boom RuntimeError HTTP\ 502 DeepSeek].each { |s| refute_includes body, s }
    end
  end

  def test_error_after_partial_deltas_still_ends_with_error_event
    ask = FakeAsk.new { |_q, &d| d.call("dở dang"); raise "boom" }
    body, err = capture_stderr { get(app_with(ask: ask), "/ask?q=x").body }
    assert_equal %w[delta error], events(body).map(&:first)
    assert_includes err, "RuntimeError"
    refute_includes err, "boom"
  end

  def test_closed_socket_is_swallowed_quietly
    ask = FakeAsk.new { |_q, &d| d.call("a"); raise Errno::EPIPE }
    body, err = capture_stderr { get(app_with(ask: ask), "/ask?q=x").body }
    assert_equal %w[delta], events(body).map(&:first)
    assert_empty err
  end

  def test_puma_connection_error_is_swallowed_quietly
    ask = FakeAsk.new { |_q, &d| d.call("a"); raise Puma::ConnectionError }
    body, err = capture_stderr { get(app_with(ask: ask), "/ask?q=x").body }
    assert_equal %w[delta], events(body).map(&:first)
    assert_empty err
  end

  def test_h_escapes_html
    out = Web.new!.h(%(<img src=x onerror=1> "q"))
    refute_includes out, "<"
    refute_includes out, '"'
  end

  def test_foreign_host_is_forbidden
    app = app_with
    assert_equal 403, get(app, "/", host: "evil.example").status
    assert_equal 403, get(app, "/ask?q=x", host: "evil.example").status
    assert_equal 200, get(app, "/", host: "localhost:4567").status
    assert_equal 200, get(app, "/", host: "127.0.0.1:4567").status
  end

  private

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    [yield, $stderr.string]
  ensure
    $stderr = old
  end
end
