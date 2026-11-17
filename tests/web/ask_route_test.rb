require "test_helper"
require "json"
require "puma"
require "puma/client"
require "rack/mock"
require_relative "../../src/web/app"

class FakeAsk
  attr_reader :calls, :histories, :kwargs

  # script: Proc(question, &on_delta) -> Answer; may raise.
  def initialize(&script)
    @script, @calls, @histories, @kwargs = script, [], [], []
  end

  def call(question, history = [], tenant_id: nil, document_ids: [], source: "cli", &on_delta)
    @calls << question
    @histories << history
    @kwargs << { tenant_id: tenant_id, document_ids: document_ids, source: source }
    @script.call(question, &on_delta)
  end
end

class AskRouteTest < Minitest::Test
  FRIENDLY = "Không thể trả lời lúc này. Vui lòng thử lại sau."

  def app_with(ask: nil, store: FakeStore.new)
    ask ||= FakeAsk.new { Rag::Answer.new("", false, []) }
    Class.new(Web) { set :ask, ask; set :store, store }
  end

  def get(app, path, host: "localhost:4567", origin: nil)
    env = { "HTTP_HOST" => host }
    env["HTTP_ORIGIN"] = origin if origin
    Rack::MockRequest.new(app).get(path, env)
  end

  def post_ask(app, body, host: "localhost:4567", origin: nil, tenant: :none)
    env = { "HTTP_HOST" => host }
    env["HTTP_X_TENANT_ID"] = tenant unless tenant == :none
    env["HTTP_ORIGIN"] = origin if origin
    json = body.is_a?(String) ? body.dup : JSON.generate(body)
    Rack::MockRequest.new(app).post("/ask", env.merge(input: json, "CONTENT_TYPE" => "application/json"))
  end

  def events(body)
    body.split("\n\n").map do |blk|
      name = blk[/\Aevent: (.+)$/, 1]
      data = blk[/^data: (.+)\z/, 1]
      [name, JSON.parse(data)]
    end
  end

  def done_store
    FakeStore.new.tap { |s| s.finish_document(s.start_document(**TestMeta.attrs("a.pdf", sha256: "x")), pages: [], chunks: []) }
  end

  def test_index_shows_title_link_and_guidance_when_no_documents
    res = get(app_with, "/")
    assert_equal 200, res.status
    assert_includes res.body, "Hỏi đáp tài liệu"
    assert_includes res.body, 'href="/documents"'
    assert_includes res.body, "Chưa có tài liệu nào. Chạy lệnh nạp (docker compose run --rm app scripts/ingest) hoặc tải file lên ở trang Tài liệu."
    assert_includes res.body, ">Tài liệu</a>"
    assert_match(%r{<button[^>]*>Hỏi</button>}, res.body)
  end

  def test_index_has_chat_hooks
    body = get(app_with, "/").body
    ['id="chat"', 'id="new-chat"', 'id="sidebar-list"'].each { |s| assert_includes body, s }
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
    res = post_ask(app_with(ask: ask), { "q" => "hello" })
    assert_includes res.content_type, "text/event-stream"
    assert_equal "no-cache", res.headers["Cache-Control"]
    assert_equal "no", res.headers["X-Accel-Buffering"]
    ev = events(res.body)
    assert_equal %w[delta delta done], ev.map(&:first)
    assert_equal ["Xin ", "chào [S1]"], ev[0, 2].map { |_, d| d["text"] }
    assert_equal true, ev[2][1]["found"]
    assert_equal({ "n" => 1, "filename" => "a.docx", "page" => 3, "quote" => "trích dẫn", "docx" => true,
                   "chunk_id" => nil, "document_id" => nil, "title" => nil, "version" => nil }, ev[2][1]["sources"][0])
  end

  def test_not_found_after_streamed_text_still_reports_found_false
    ask = FakeAsk.new { |_q, &d| d.call("bịa"); Rag::Answer.new("bịa", false, []) }
    ev = events(post_ask(app_with(ask: ask), { "q" => "x" }).body)
    assert_equal %w[delta done], ev.map(&:first)
    assert_equal false, ev.last[1]["found"]
    assert_equal "", ev.last[1]["text"]
    assert_empty ev.last[1]["sources"]
  end

  def test_multiline_answer_with_script_tag_is_one_data_line
    text = "dòng 1\n</script><b>x</b>"
    ask = FakeAsk.new { |_q, &d| d.call(text); Rag::Answer.new(text, true, [Rag::Source.new(2, "B.PDF", 1, nil)]) }
    body = post_ask(app_with(ask: ask), { "q" => "x" }).body
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
    [{ "q" => "  " }, {}, { "q" => 1 }].each { |b| assert_equal 400, post_ask(app, b).status }
    assert_empty ask.calls
  end

  def test_ask_error_gives_friendly_event_without_details
    [Rag::DeepSeek::Error.new("Không gọi được DeepSeek (HTTP 502)"), RuntimeError.new("boom")].each do |err|
      ask = FakeAsk.new { raise err }
      body = capture_stderr { post_ask(app_with(ask: ask), { "q" => "x" }).body }.first
      assert_equal [["error", { "message" => FRIENDLY }]], events(body)
      %w[boom RuntimeError HTTP\ 502 DeepSeek].each { |s| refute_includes body, s }
    end
  end

  def test_error_after_partial_deltas_still_ends_with_error_event
    ask = FakeAsk.new { |_q, &d| d.call("dở dang"); raise "boom" }
    body, err = capture_stderr { post_ask(app_with(ask: ask), { "q" => "x" }).body }
    assert_equal %w[delta error], events(body).map(&:first)
    assert_includes err, "RuntimeError"
    refute_includes err, "boom"
  end

  def test_closed_socket_is_swallowed_quietly
    ask = FakeAsk.new { |_q, &d| d.call("a"); raise Errno::EPIPE }
    body, err = capture_stderr { post_ask(app_with(ask: ask), { "q" => "x" }).body }
    assert_equal %w[delta], events(body).map(&:first)
    assert_empty err
  end

  def test_puma_connection_error_is_swallowed_quietly
    ask = FakeAsk.new { |_q, &d| d.call("a"); raise Puma::ConnectionError }
    body, err = capture_stderr { post_ask(app_with(ask: ask), { "q" => "x" }).body }
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
    assert_equal 403, post_ask(app, { "q" => "x" }, host: "evil.example").status
    assert_equal 200, get(app, "/", host: "localhost:4567").status
    assert_equal 200, get(app, "/", host: "127.0.0.1:4567").status
  end

  def test_public_hosts_strips_scheme_and_slash
    assert_equal ["a.example", "b.example"], Web.public_hosts(" https://a.example/ , b.example,")
    assert_equal [], Web.public_hosts(nil)
  end

  def test_public_host_is_allowed_as_host_and_origin
    app = app_with
    app.set :host_authorization, permitted_hosts: ["localhost", "tunnel.example"]
    assert_equal 200, get(app, "/", host: "tunnel.example").status
    assert_equal 200, post_ask(app, { "q" => "x" }, host: "tunnel.example", origin: "https://tunnel.example").status
    assert_equal 403, get(app, "/", host: "evil.example").status
    assert_equal 403, get(app, "/", host: "tunnel.example", origin: "https://evil.example").status
  end

  def test_foreign_origin_is_forbidden_on_every_method_and_ask_not_called
    ask = FakeAsk.new { Rag::Answer.new("", false, []) }
    app = app_with(ask: ask)
    assert_equal 403, post_ask(app, { "q" => "x" }, origin: "http://evil.example").status
    assert_equal 403, get(app, "/", origin: "http://evil.example").status
    assert_empty ask.calls
    assert_equal 200, post_ask(app, { "q" => "x" }).status
    assert_equal 200, get(app, "/", origin: "http://localhost:4567").status
    assert_equal ["x"], ask.calls
  end

  def test_get_ask_is_not_served
    ask = FakeAsk.new { raise "must not be called" }
    assert_equal 404, get(app_with(ask: ask), "/ask?q=x").status
    assert_empty ask.calls
  end

  def test_done_event_carries_standalone_only_when_it_differs
    [["Hoàn tiền trong bao lâu?", "Hoàn tiền trong bao lâu?"], ["còn hoàn tiền?", nil], [nil, nil]].each do |standalone, expected|
      ask = FakeAsk.new { Rag::Answer.new("t", true, [], standalone) }
      done = events(post_ask(app_with(ask: ask), { "q" => "còn hoàn tiền?" }).body).last[1]
      if expected
        assert_equal expected, done["standalone"]
      else
        refute done.key?("standalone")
      end
    end
  end

  def test_first_turn_standalone_equal_after_squash_is_omitted
    q = "Hoàn  tiền\u00A0trong bao lâu?"
    ask = FakeAsk.new { Rag::Answer.new("t", true, [], q) }
    done = events(post_ask(app_with(ask: ask), { "q" => q }).body).last[1]
    refute done.key?("standalone")
  end

  def test_bad_bodies_are_400_and_ask_not_called
    ask = FakeAsk.new { raise "must not be called" }
    app = app_with(ask: ask)
    ["{not json", "[]", "\"str\"", "null",
     { "q" => "x", "history" => nil }, { "q" => "x", "history" => {} }, { "q" => "x", "history" => ["s"] },
     { "q" => "x", "history" => [{ "q" => "a" }] }, { "q" => "x", "history" => [{ "q" => 1, "a" => "b" }] },
     { "q" => "x", "history" => [{ "q" => "a", "a" => nil }] },
     "{\"q\":\"a\xff\"}".b, "{\"q\":\"x\",\"history\":[{\"q\":\"a\xff\",\"a\":\"b\"}]}".b,
     "{\"q\":\"x\",\"history\":[{\"q\":\"a\",\"a\":\"b\xff\"}]}".b].each do |b|
      res = post_ask(app, b)
      assert_equal 400, res.status, b.inspect
      refute_includes res.content_type.to_s, "text/event-stream"
    end
    assert_empty ask.calls
  end

  def test_missing_history_is_empty_array
    ask = FakeAsk.new { Rag::Answer.new("", false, []) }
    post_ask(app_with(ask: ask), { "q" => "x" })
    assert_equal [[]], ask.histories
  end

  def test_history_keeps_last_three_turns_and_cuts_lengths_by_characters
    turns = (1..4).map { |i| { "q" => "q#{i}", "a" => "a#{i}" } } + [{ "q" => "ế" * 1500, "a" => "ế" * 2500 }]
    ask = FakeAsk.new { Rag::Answer.new("", false, []) }
    post_ask(app_with(ask: ask), { "q" => "x", "history" => turns })
    h = ask.histories.last
    assert_equal 3, h.size
    assert_equal [{ q: "q3", a: "a3" }, { q: "q4", a: "a4" }], h[0, 2]
    assert_equal [:q, :a], h[2].keys
    assert_equal 1000, h[2][:q].size
    assert_equal 2000, h[2][:a].size
    assert h[2][:q].valid_encoding? && h[2][:a].valid_encoding?
  end

  def test_ask_works_when_rack_input_is_not_rewindable
    # Rack 3 does not require rack.input to respond to rewind; Rack::Lint's wrapper does not.
    app = app_with(ask: FakeAsk.new { Rag::Answer.new("ok", true, []) })
    ok = Rack::MockRequest.new(app).post("/ask", "HTTP_HOST" => "localhost:4567", "CONTENT_TYPE" => "application/json",
                                                  input: JSON.generate("q" => "hi"), lint: true)
    assert_equal 200, ok.status
    blank = Rack::MockRequest.new(app).post("/ask", "HTTP_HOST" => "localhost:4567", "CONTENT_TYPE" => "application/json",
                                                     input: JSON.generate("q" => " "), lint: true)
    assert_equal 400, blank.status
  end

  def test_body_over_64kb_is_413_and_ask_not_called
    ask = FakeAsk.new { Rag::Answer.new("", false, []) }
    app = app_with(ask: ask)
    body = ->(n) { pad = JSON.generate({ "q" => "" }).bytesize; JSON.generate({ "q" => "a" * (n - pad) }) }
    assert_equal 413, post_ask(app, body.call(65_537)).status
    assert_empty ask.calls
    assert_equal 65_537, body.call(65_537).bytesize
    assert_equal 200, post_ask(app, body.call(65_536)).status
    assert_equal 1, ask.calls.size
    env = { "HTTP_HOST" => "localhost:4567", "CONTENT_LENGTH" => "65537", input: +"{}", "CONTENT_TYPE" => "application/json" }
    assert_equal 413, Rack::MockRequest.new(app).post("/ask", env).status
    assert_equal 1, ask.calls.size
  end

  def test_ask_passes_tenant_header_and_document_ids_and_source_web
    ask = FakeAsk.new { Rag::Answer.new("", false, []) }
    post_ask(app_with(ask: ask), { "q" => "x", "document_ids" => [3, 5] }, tenant: "acme")
    assert_equal [{ tenant_id: "acme", document_ids: [3, 5], source: "web" }], ask.kwargs
  end

  def test_missing_tenant_header_uses_default
    ask = FakeAsk.new { Rag::Answer.new("", false, []) }
    post_ask(app_with(ask: ask), { "q" => "x" })
    assert_equal [{ tenant_id: Rag::DEFAULT_TENANT, document_ids: [], source: "web" }], ask.kwargs
  end

  def test_unknown_or_blank_tenant_header_is_400_and_ask_not_called
    ask = FakeAsk.new { raise "must not be called" }
    app = app_with(ask: ask)
    ["", "NUS", " nus", "zzz"].each { |t| assert_equal 400, post_ask(app, { "q" => "x" }, tenant: t).status, t.inspect }
    assert_empty ask.calls
  end

  def test_document_ids_validation
    ask = FakeAsk.new { raise "must not be called" }
    app = app_with(ask: ask)
    ["1", [0], [-1], ["a"], [1.5], [nil], (1..201).to_a, {}].each do |ids|
      assert_equal 400, post_ask(app, { "q" => "x", "document_ids" => ids }).status, ids.inspect
    end
    assert_empty ask.calls
    ok = FakeAsk.new { Rag::Answer.new("", false, []) }
    assert_equal 200, post_ask(app_with(ask: ok), { "q" => "x", "document_ids" => (1..200).to_a }).status
  end

  def test_done_event_carries_chunks_and_source_ids
    hit = Rag::Hit.new(filename: "a.pdf", page: 2, text: "nội dung", distance: 0.12345, chunk_id: 9, document_id: 4, title: "Chính sách", version: 3)
    src = Rag::Source.new(1, "a.pdf", 2, "nội", 9, 4, "Chính sách", 3)
    ask = FakeAsk.new { Rag::Answer.new("t [S1]", true, [src], nil, [hit]) }
    done = events(post_ask(app_with(ask: ask), { "q" => "x" }).body).last[1]
    assert_equal({ "chunk_id" => 9, "document_id" => 4, "title" => "Chính sách", "version" => 3, "page" => 2, "score" => 0.877, "content" => "nội dung" }, done["chunks"][0])
    assert_equal [9, 4, "Chính sách", 3], done["sources"][0].values_at("chunk_id", "document_id", "title", "version")
  end

  def test_done_event_has_chunks_when_not_found
    hit = Rag::Hit.new(filename: "a.pdf", page: 1, text: "y", distance: 0.7, chunk_id: 1, document_id: 1, title: "T", version: 1)
    ask = FakeAsk.new { Rag::Answer.new("", false, [], nil, [hit]) }
    done = events(post_ask(app_with(ask: ask), { "q" => "x" }).body).last[1]
    assert_equal false, done["found"]
    assert_equal [0.3], done["chunks"].map { |c| c["score"] }
  end

  def test_index_has_tenant_select_scope_and_chunk_hooks
    body = get(app_with, "/").body
    assert_match(/<select id="tenant"/, body)
    assert_match(/<option value="nus" selected>/, body)
    assert_match(/<option value="acme">/, body)
    assert_includes body, 'id="scope"'
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
