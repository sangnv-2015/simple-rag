require "test_helper"
require "tmpdir"
require "stringio"
require "rack/mock"
require_relative "../../src/web/app"

class FakeWorker
  attr_reader :enqueued
  attr_accessor :names

  def initialize = (@enqueued, @names = [], [])
  def enqueue(path) = @enqueued << path
  def pending = @names
end

class DocumentsRouteTest < Minitest::Test
  HOST = "localhost:4567"
  EVIL = %(<script>alert(1)</script>"><img src=x onerror=1>)
  EVIL_ESCAPED = "&lt;script&gt;alert(1)&lt;/script&gt;&quot;&gt;&lt;img src=x onerror=1&gt;"

  def setup
    @dir = Dir.mktmpdir
    @store = FakeStore.new
    @worker = FakeWorker.new
  end

  def teardown = FileUtils.remove_entry(@dir)

  def app(max: 1000)
    store, worker, dir = @store, @worker, @dir
    Class.new(Web) { set :store, store; set :worker, worker; set :documents_dir, dir; set :max_upload_bytes, max }
  end

  def req = Rack::MockRequest.new(app)

  def get(path, **env) = Rack::MockRequest.new(app).get(path, { "HTTP_HOST" => HOST }.merge(env))

  def upload(name: "a.pdf", body: "%PDF-1.4 hi", max: 1000, field: "file", io: nil, env: {})
    boundary = "xBOUNDARY"
    payload = "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{field}\"; filename=\"#{name}\"\r\n" \
              "Content-Type: application/octet-stream\r\n\r\n#{body}\r\n--#{boundary}--\r\n"
    Rack::MockRequest.new(app(max: max)).post("/documents", {
      "HTTP_HOST" => HOST, "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}", input: payload
    }.merge(env))
  end

  def add(name, status: "done", error: nil, pages: [])
    id = @store.start_document(**TestMeta.attrs(name, sha256: "x"))
    case status
    when "done" then @store.finish_document(id, pages: pages, chunks: [])
    when "error" then @store.fail_document(id, error)
    end
  end

  def page(n, raw: "raw #{n}", md: "md #{n}", readable: true, fallback: false)
    Rag::Page.new(number: n, raw_text: raw, markdown: md, readable: readable, fallback: fallback)
  end

  def test_list_shows_name_counts_and_status_labels
    add("done.pdf", pages: [page(1), page(2)])
    add("busy.pdf", status: "processing")
    add("bad.pdf", status: "error", error: "file scan, không đọc được")
    add("wait.pdf")
    @worker.names = ["busy.pdf", "wait.pdf"]
    body = get("/documents").body
    row = ->(name) { body[%r{<tr>(?:(?!</tr>).)*#{Regexp.escape(name)}\.pdf(?:(?!</tr>).)*</tr>}m] }
    assert_match(%r{done\.pdf.*<td>2</td>\s*<td>0</td>\s*<td>xong</td>}m, row.("done"))
    assert_includes row.("busy"), "đang xử lý"
    assert_includes row.("bad"), "lỗi: file scan, không đọc được"
    assert_includes row.("wait"), "đang chờ"
    assert_includes body, "Số trang"
    assert_includes body, "Số đoạn"
    assert_includes body, 'name="file"'
    assert_includes body, "Tải lên"
    assert_includes body, 'href="/"'
    assert_includes body, "Hỏi đáp"
  end

  def test_list_shows_just_uploaded_name_not_yet_in_store_as_queued
    @worker.names = ["new.pdf"]
    body = get("/documents").body
    assert_includes body, "new.pdf"
    assert_includes body, "đang chờ"
  end

  def test_list_refreshes_only_while_something_is_in_progress
    add("done.pdf")
    refute_includes get("/documents").body, 'http-equiv="refresh"'
    @worker.names = ["done.pdf"]
    assert_includes get("/documents").body, '<meta http-equiv="refresh" content="3">'
    @worker.names = []
    add("busy.pdf", status: "processing")
    @worker.names = ["busy.pdf"]
    assert_includes get("/documents").body, 'http-equiv="refresh"'
  end

  def test_interrupted_processing_document_is_an_error_and_does_not_refresh
    add("stuck.pdf", status: "processing")
    body = get("/documents").body
    assert_includes body, "lỗi: bị gián đoạn, hãy tải lại file hoặc chạy lại lệnh nạp"
    refute_includes body, "đang xử lý"
    refute_includes body, 'http-equiv="refresh"'
  end

  def test_list_escapes_html_everywhere
    add("#{EVIL}.pdf", pages: [page(1)])
    add("bad#{EVIL}.pdf", status: "error", error: EVIL)
    body = get("/documents").body
    refute_includes body, "<script>alert"
    refute_includes body, "<img src=x"
    assert_includes body, EVIL_ESCAPED
    assert_includes body, "lỗi: #{EVIL_ESCAPED}"
    assert_includes body, "/documents/#{ERB::Util.url_encode("#{EVIL}.pdf")}"
  end

  def test_upload_valid_pdf_saves_enqueues_and_redirects
    res = upload
    assert_equal 303, res.status
    assert_match %r{/documents\z}, res.headers["Location"]
    path = File.join(File.realpath(@dir), "a.pdf")
    assert_equal "%PDF-1.4 hi", File.read(path)
    assert_equal [path], @worker.enqueued
  end

  def test_upload_rejects_other_extension_and_too_large
    res = upload(name: "a.txt")
    assert_equal 422, res.status
    assert_includes res.body, "Chỉ nhận file .pdf và .docx."
    res = upload(name: "big.pdf", body: "x" * 50, max: 10)
    assert_equal 422, res.status
    assert_includes res.body, "File quá lớn (tối đa 30 MB)."
    assert_empty Dir.children(@dir)
    assert_empty @worker.enqueued
  end

  def test_upload_traversal_name_stays_inside_documents_dir
    res = upload(name: "../../evil.pdf")
    assert_equal 303, res.status
    assert_equal ["evil.pdf"], Dir.children(@dir)
    assert_equal [File.join(File.realpath(@dir), "evil.pdf")], @worker.enqueued
  end

  def test_upload_without_file_is_400
    res = upload(field: "other")
    assert_equal 400, res.status
    assert_includes res.body, "Chọn một file để tải lên."
    assert_empty @worker.enqueued
  end

  def test_upload_unexpected_failure_is_500_with_fixed_message_and_class_only_logged
    FileUtils.remove_entry(@dir) # realpath of the documents dir now raises Errno::ENOENT
    begin
      _, err = capture_io do
        res = upload
        assert_equal 500, res.status
        assert_includes res.body, "Không tải được file lên. Vui lòng thử lại."
        refute_includes res.body, @dir
      end
      assert_includes err, "Errno::ENOENT"
      refute_includes err, @dir
      assert_empty @worker.enqueued
    ensure
      Dir.mkdir(@dir)
    end
  end

  def test_percent_encoded_path_does_not_bypass_origin_or_size_guard
    res = Rack::MockRequest.new(app).post("/%64ocuments", "HTTP_HOST" => HOST, "HTTP_ORIGIN" => "http://evil.example",
      "CONTENT_TYPE" => "multipart/form-data; boundary=x", input: "--x--\r\n")
    assert_equal 403, res.status
    assert_empty Dir.children(@dir)
    res = Rack::MockRequest.new(app(max: 1000)).post("/%64ocuments", "HTTP_HOST" => HOST,
      "CONTENT_TYPE" => "multipart/form-data; boundary=x", "CONTENT_LENGTH" => (1000 + 1024 * 1024 + 1).to_s, input: StringIO.new)
    assert_equal 413, res.status
  end

  def test_file_param_without_a_real_upload_is_400
    res = Rack::MockRequest.new(app).post("/documents", "HTTP_HOST" => HOST,
      "CONTENT_TYPE" => "application/x-www-form-urlencoded", input: "file[tempfile]=x&file[filename]=a.pdf")
    assert_equal 400, res.status
    assert_includes res.body, "Chọn một file để tải lên."
  end

  def test_rejection_message_page_does_not_auto_refresh
    @worker.names = ["busy.pdf"]
    res = upload(name: "a.txt")
    assert_equal 422, res.status
    refute_includes res.body, 'http-equiv="refresh"'
  end

  def test_temp_files_are_reaped_by_middleware
    assert Web.middleware.any? { |m| m.first == Rack::TempfileReaper }
  end

  def test_upload_with_huge_content_length_is_413_without_reading_body
    res = Rack::MockRequest.new(app(max: 1000)).post("/documents", "HTTP_HOST" => HOST,
      "CONTENT_TYPE" => "multipart/form-data; boundary=x", "CONTENT_LENGTH" => (1000 + 1024 * 1024 + 1).to_s,
      input: Class.new { def read(*) = raise("must not be read"); def each = raise("must not be read"); def rewind = nil; def gets = raise("no") }.new)
    assert_equal 413, res.status
    assert_includes res.body, "File quá lớn (tối đa 30 MB)."
    assert_empty Dir.children(@dir)
  end

  def test_upload_origin_check
    res = upload(env: { "HTTP_ORIGIN" => "http://evil.example" })
    assert_equal 403, res.status
    assert_empty Dir.children(@dir)
    assert_empty @worker.enqueued
    assert_equal 403, upload(env: { "HTTP_ORIGIN" => "null" }).status
    assert_equal 303, upload.status
    assert_equal 303, upload(name: "b.pdf", env: { "HTTP_ORIGIN" => "http://localhost:4567" }).status
    assert_equal 303, upload(name: "c.pdf", env: { "HTTP_ORIGIN" => "http://[::1]:4567" }).status
    assert_equal 303, upload(name: "d.pdf", env: { "HTTP_ORIGIN" => "http://127.0.0.1" }).status
  end

  def test_viewer_shows_two_columns_flags_and_unreadable_page
    add("a.pdf", pages: [page(1, raw: "chữ gốc 1", md: "| a | b |"), page(2, fallback: true), page(3, raw: "", md: "", readable: false)])
    body = get("/documents/a.pdf?page=2").body
    assert_includes body, "Chữ gốc"
    assert_includes body, "Markdown (DeepSeek dựng lại)"
    assert_includes body, "chữ gốc 1"
    assert_includes body, "| a | b |"
    assert_includes body, "Đã dùng chữ gốc vì markdown thiếu số liệu"
    assert_includes body, "Trang không đọc được (không có lớp chữ)"
    %w[page-1 page-2 page-3].each { |id| assert_includes body, %(id="#{id}") }
    assert_equal 1, body.scan("Đã dùng chữ gốc vì markdown thiếu số liệu").size
    assert_match(/id="page-2"[^>]*class="[^"]*current|class="[^"]*current[^"]*"[^>]*id="page-2"/, body)
    refute_match(/id="page-1"[^>]*current/, body)
    assert_includes body, 'href="/documents"'
    assert_includes body, "Hỏi đáp"
  end

  def test_viewer_highlights_quote_on_current_page_and_collapses_others
    add("a.pdf", pages: [page(1, raw: "x <b> y"), page(2, raw: "trước <b>đoạn\n trích</b> sau", md: "đoạn trích")])
    body = get("/documents/a.pdf?page=2&q=#{Rack::Utils.escape("<b>đoạn trích</b>")}").body
    assert_includes body, %(trước <mark id="hit">&lt;b&gt;đoạn\n trích&lt;/b&gt;</mark> sau)
    assert_equal 1, body.scan("<mark").size
    assert_includes body, "<details><summary>Trang 1</summary>"
    refute_includes body, "<details><summary>Trang 2</summary>"
    refute_includes get("/documents/a.pdf?q=x").body, "<mark>" # no page, no highlight
  end

  def test_viewer_marks_docx_pages_as_pdf_version
    add("a.docx", pages: [page(1), page(2)])
    add("b.pdf", pages: [page(1)])
    body = get("/documents/a.docx?page=2").body
    assert_includes body, "Trang 2 (bản PDF)"
    assert_includes body, 'id="page-2"'
    refute_includes get("/documents/b.pdf").body, "bản PDF"
  end

  def test_viewer_ignores_invalid_or_out_of_range_page
    add("a.pdf", pages: [page(1)])
    ["abc", "99", "-1", "1<script>"].each do |p|
      res = get("/documents/a.pdf?page=#{Rack::Utils.escape(p)}")
      assert_equal 200, res.status
      refute_includes res.body, "page current"
      refute_includes res.body, "<script>"
    end
  end

  def test_viewer_escapes_html_in_content
    name = "#{EVIL}.pdf"
    add(name, pages: [page(1, raw: EVIL, md: EVIL)])
    body = get("/documents/#{ERB::Util.url_encode(name)}").body
    assert_equal 200, get("/documents/#{ERB::Util.url_encode(name)}").status
    refute_includes body, "<script>alert"
    refute_includes body, "<img src=x"
    assert_operator body.scan(EVIL_ESCAPED).size, :>=, 3 # name (title), raw, markdown
  end

  def test_viewer_unknown_file_is_404
    assert_equal 404, get("/documents/nope.pdf").status
    assert_equal 404, get("/documents/%00.pdf").status
    assert_equal 404, get("/documents/%FF.pdf").status
  end

  def test_viewer_handles_spaces_diacritics_and_nfd_request
    name = "Quy định nghỉ phép.pdf"
    add(name, pages: [page(1)])
    [name, name.unicode_normalize(:nfd)].each do |n|
      res = get("/documents/#{ERB::Util.url_encode(n)}")
      assert_equal 200, res.status
      assert_includes res.body, name
    end
  end
end
