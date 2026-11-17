require "test_helper"
require "tmpdir"
require "stringio"
require "rack/mock"
require_relative "../../src/web/app"

class DocumentsRouteTest < Minitest::Test
  HOST = "localhost:4567"
  EVIL = %(<script>alert(1)</script>"><img src=x onerror=1>)
  EVIL_ESCAPED = "&lt;script&gt;alert(1)&lt;/script&gt;&quot;&gt;&lt;img src=x onerror=1&gt;"

  def setup
    @dir = Dir.mktmpdir
    @store = FakeStore.new
    @worker = FakeWorker.new
    @ingest = Rag::Ingest.new(llm: nil, embedder: FakeEmbedder.new, store: @store)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def app(max: 1000)
    store, worker, dir, ingest = @store, @worker, @dir, @ingest
    Class.new(Web) { set :store, store; set :worker, worker; set :ingest, ingest; set :documents_dir, dir; set :max_upload_bytes, max }
  end

  def req = Rack::MockRequest.new(app)

  def get(path, **env) = Rack::MockRequest.new(app).get(path, { "HTTP_HOST" => HOST }.merge(env))

  META = { "tenant_id" => "nus", "title" => "Quy chế", "version" => "1", "valid_from" => "2026-01-01", "valid_to" => "2026-12-31" }.freeze

  def upload(name: "a.pdf", body: "%PDF-1.4 hi", max: 1000, field: "file", env: {}, meta: {})
    boundary = "xBOUNDARY"
    fields = META.merge(meta.transform_keys(&:to_s)).map do |k, v|
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}\r\n"
    end.join
    payload = "#{fields}--#{boundary}\r\nContent-Disposition: form-data; name=\"#{field}\"; filename=\"#{name}\"\r\n" \
              "Content-Type: application/octet-stream\r\n\r\n#{body}\r\n--#{boundary}--\r\n"
    Rack::MockRequest.new(app(max: max)).post("/documents", {
      "HTTP_HOST" => HOST, "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}", input: payload
    }.merge(env))
  end

  def post_form(path, tenant_id:, env: {})
    Rack::MockRequest.new(app).post(path, { "HTTP_HOST" => HOST, "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                                           input: Rack::Utils.build_query(tenant_id: tenant_id) }.merge(env))
  end

  def uploads(tenant = "nus") = Dir.glob(File.join(@dir, "uploads", tenant, "*"))

  def add(name, status: "done", error: nil, pages: [], **over)
    id = @store.start_document(**TestMeta.attrs(name, sha256: "x", **over))
    case status
    when "done" then @store.finish_document(id, pages: pages, chunks: [])
    when "error" then @store.fail_document(id, error)
    end
    id
  end

  def page(n, raw: "raw #{n}", md: "md #{n}", readable: true, fallback: false)
    Rag::Page.new(number: n, raw_text: raw, markdown: md, readable: readable, fallback: fallback)
  end

  def row(body, name) = body[%r{<tr>(?:(?!</tr>).)*#{Regexp.escape(name)}(?:(?!</tr>).)*</tr>}m]

  def test_list_shows_metadata_counts_status_and_delete_form
    id = add("done.pdf", pages: [page(1), page(2)], title: "Quy chế", version: 3,
                         valid_from: Date.new(2026, 1, 1), valid_to: Date.new(2026, 12, 31))
    r = row(get("/documents").body, "Quy chế")
    assert_includes r, "v3"
    assert_includes r, "2026-01-01"
    assert_includes r, "2026-12-31"
    assert_match(%r{<td>2</td>\s*<td>0</td>\s*<td>xong</td>}m, r)
    assert_includes r, %(action="/documents/#{id}/delete")
    assert_includes r, 'name="tenant_id" value="nus"'
    body = get("/documents").body
    ["Số trang", "Số đoạn", 'name="file"', "Tải lên", 'href="/"', "Hỏi đáp", 'name="title"', 'name="version"',
     'name="valid_from"', 'name="valid_to"', "rag.tenant"].each { |t| assert_includes body, t }
    assert_includes body, %(href="/documents/#{id}")
  end

  def test_list_status_labels_by_pending_ids
    busy = add("busy.pdf", status: "processing")
    add("bad.pdf", status: "error", error: "file scan, không đọc được")
    wait = add("wait.pdf", status: "processing")
    add("stuck.pdf", status: "processing")
    @worker.names = [busy, wait]
    body = get("/documents").body
    assert_includes row(body, "busy.pdf"), "đang xử lý"
    assert_includes row(body, "bad.pdf"), "lỗi: file scan, không đọc được"
    assert_includes row(body, "stuck.pdf"), "lỗi: bị gián đoạn, hãy tải lại file hoặc chạy lại lệnh nạp"
    refute_includes row(body, "stuck.pdf"), "đang xử lý"
  end

  def test_expired_rows_are_visible_and_marked
    add("old.pdf", title: "Cũ").then { |id| @store.instance_variable_get(:@docs)[id][:doc].status = "expired" }
    assert_includes row(get("/documents").body, "old.pdf"), "hết hiệu lực"
  end

  def test_list_is_scoped_by_tenant_param_and_unknown_tenant_is_400
    add("n.pdf")
    add("ac.pdf", tenant_id: "acme")
    body = get("/documents?tenant=acme").body
    assert_includes body, "ac.pdf"
    refute_includes body, "n.pdf"
    body = get("/documents").body
    assert_includes body, "n.pdf"
    refute_includes body, "ac.pdf"
    assert_equal 400, get("/documents?tenant=evil").status
  end

  def test_list_refreshes_only_while_something_is_in_progress
    id = add("done.pdf")
    refute_includes get("/documents").body, 'http-equiv="refresh"'
    @worker.names = [id]
    assert_includes get("/documents").body, '<meta http-equiv="refresh" content="3">'
    @worker.names = []
    busy = add("busy.pdf", status: "processing", title: "b")
    @worker.names = [busy]
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
    add("bad#{EVIL}.pdf", status: "error", error: EVIL, title: EVIL)
    body = get("/documents").body
    refute_includes body, "<script>alert"
    refute_includes body, "<img src=x"
    assert_includes body, EVIL_ESCAPED
    assert_includes body, "lỗi: #{EVIL_ESCAPED}"
  end

  def test_upload_valid_pdf_saves_enqueues_and_redirects
    res = upload
    assert_equal 303, res.status
    assert_match %r{/documents\?tenant=nus\z}, res.headers["Location"]
    path = uploads.fetch(0)
    assert_match %r{/uploads/nus/[0-9a-f-]{36}-a\.pdf\z}, path
    assert_equal "%PDF-1.4 hi", File.read(path)
    doc = @store.documents.fetch(0)
    assert_equal [[doc.id, path]], @worker.enqueued
    assert_equal ["processing", "Quy chế", 1, Date.new(2026, 1, 1), Date.new(2026, 12, 31), "nus", "a.pdf"],
                 [doc.status, doc.title, doc.version, doc.valid_from, doc.valid_to, doc.tenant_id, doc.filename]
  end

  def test_upload_invalid_metadata_is_422_and_leaves_nothing
    [[{ title: " " }, "Tiêu đề phải có từ 1 đến 200 ký tự."], [{ version: "0" }, "Phiên bản phải là số nguyên dương."],
     [{ valid_from: "2027-01-01" }, "Ngày hết hiệu lực phải sau hoặc bằng ngày bắt đầu."],
     [{ tenant_id: "evil" }, "Tenant không hợp lệ."], [{ valid_to: "" }, "Ngày phải có dạng YYYY-MM-DD."]].each do |m, msg|
      res = upload(meta: m)
      assert_equal 422, res.status, m.inspect
      assert_match(/role="alert">#{Regexp.escape(msg)}</, res.body)
      assert_empty uploads
      assert_empty uploads("evil")
      assert_empty @worker.enqueued
      assert_empty @store.documents
    end
    refute File.exist?(File.join(@dir, "uploads", "evil"))
  end

  def test_upload_same_sha256_of_done_document_is_303_without_enqueue_and_removes_duplicate
    id = @store.start_document(**TestMeta.attrs("a.pdf", title: "Quy chế", sha256: Digest::SHA256.hexdigest("%PDF-1.4 hi"),
                                                valid_from: Date.new(2026, 1, 1), valid_to: Date.new(2026, 12, 31)))
    @store.finish_document(id, pages: [], chunks: [])
    res = upload
    assert_equal 303, res.status
    assert_empty uploads
    assert_empty @worker.enqueued
    assert_equal 1, @store.documents.size
  end

  def test_reupload_of_same_title_and_version_leaves_only_the_new_file
    assert_equal 303, upload(body: "%PDF-1.4 one").status
    assert_equal 303, upload(body: "%PDF-1.4 two").status
    assert_equal 1, uploads.size
    assert_equal "%PDF-1.4 two", File.read(uploads.fetch(0))
    assert_equal 1, @store.documents.size
  end

  def test_list_refresh_ignores_pending_ids_of_other_tenants
    other = add("ac.pdf", tenant_id: "acme", status: "processing")
    add("n.pdf")
    @worker.names = [other]
    refute_includes get("/documents").body, 'http-equiv="refresh"'
    assert_includes get("/documents?tenant=acme").body, 'http-equiv="refresh"'
  end

  def test_upload_removes_saved_file_when_prepare_raises
    @ingest.define_singleton_method(:prepare) { |*, **| raise "boom" }
    capture_io { assert_equal 500, upload.status }
    assert_empty uploads
    assert_empty @worker.enqueued
  end

  def test_upload_rejects_other_extension_and_too_large
    res = upload(name: "a.txt")
    assert_equal 422, res.status
    assert_includes res.body, "Chỉ nhận file .pdf và .docx."
    res = upload(name: "big.pdf", body: "x" * 50, max: 10)
    assert_equal 422, res.status
    assert_includes res.body, "File quá lớn (tối đa 30 MB)."
    assert_empty uploads
    assert_empty @worker.enqueued
  end

  def test_upload_traversal_name_stays_inside_documents_dir
    res = upload(name: "../../evil.pdf")
    assert_equal 303, res.status
    assert_match %r{/uploads/nus/[0-9a-f-]{36}-evil\.pdf\z}, uploads.fetch(0)
    assert_equal [[1, uploads.fetch(0)]], @worker.enqueued
  end

  def test_upload_without_file_is_400
    res = upload(field: "other")
    assert_equal 400, res.status
    assert_includes res.body, "Chọn một file để tải lên."
    assert_empty @worker.enqueued
  end

  def test_upload_unexpected_failure_is_500_with_fixed_message_and_class_only_logged
    FileUtils.remove_entry(@dir) # the documents dir is now a plain file: creating uploads/ under it raises Errno::EEXIST
    File.write(@dir, "x")
    begin
      _, err = capture_io do
        res = upload
        assert_equal 500, res.status
        assert_includes res.body, "Không tải được file lên. Vui lòng thử lại."
        refute_includes res.body, @dir
      end
      assert_includes err, "Errno::EEXIST"
      refute_includes err, @dir
      assert_empty @worker.enqueued
    ensure
      File.delete(@dir)
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
    assert_equal 303, upload(name: "d.pdf", env: { "HTTP_ORIGIN" => "http://127.0.0.1:4567" }).status
  end

  def test_viewer_shows_two_columns_flags_and_unreadable_page
    id = add("a.pdf", pages: [page(1, raw: "chữ gốc 1", md: "| a | b |"), page(2, fallback: true), page(3, raw: "", md: "", readable: false)])
    body = get("/documents/#{id}?page=2").body
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
    id = add("a.pdf", pages: [page(1, raw: "x <b> y"), page(2, raw: "trước <b>đoạn\n trích</b> sau", md: "đoạn trích")])
    body = get("/documents/#{id}?page=2&q=#{Rack::Utils.escape("<b>đoạn trích</b>")}").body
    assert_includes body, %(trước <mark id="hit">&lt;b&gt;đoạn\n trích&lt;/b&gt;</mark> sau)
    assert_equal 1, body.scan("<mark").size
    assert_includes body, "<details><summary>Trang 1</summary>"
    refute_includes body, "<details><summary>Trang 2</summary>"
    refute_includes get("/documents/#{id}?q=x").body, "<mark>" # no page, no highlight
  end

  def test_viewer_marks_docx_pages_as_pdf_version
    d = add("a.docx", pages: [page(1), page(2)])
    p = add("b.pdf", pages: [page(1)], title: "b")
    body = get("/documents/#{d}?page=2").body
    assert_includes body, "Trang 2 (bản PDF)"
    assert_includes body, 'id="page-2"'
    refute_includes get("/documents/#{p}").body, "bản PDF"
  end

  def test_viewer_ignores_invalid_or_out_of_range_page
    id = add("a.pdf", pages: [page(1)])
    ["abc", "99", "-1", "1<script>"].each do |p|
      res = get("/documents/#{id}?page=#{Rack::Utils.escape(p)}")
      assert_equal 200, res.status
      refute_includes res.body, "page current"
      refute_includes res.body, "<script>"
    end
  end

  def test_viewer_escapes_html_in_content
    id = add("#{EVIL}.pdf", pages: [page(1, raw: EVIL, md: EVIL)])
    res = get("/documents/#{id}")
    assert_equal 200, res.status
    refute_includes res.body, "<script>alert"
    refute_includes res.body, "<img src=x"
    assert_operator res.body.scan(EVIL_ESCAPED).size, :>=, 3 # name, raw, markdown
  end

  def test_viewer_unknown_id_and_filename_urls_are_404
    id = add("a.pdf")
    assert_equal 404, get("/documents/#{id + 99}").status
    assert_equal 404, get("/documents/a.pdf").status
    assert_equal 404, get("/documents/%00").status
    assert_equal 404, get("/documents/%FF").status
    assert_equal 404, get("/documents/99999999999999999999999").status
  end

  def test_viewer_shows_diacritic_name
    id = add("Quy định nghỉ phép.pdf", pages: [page(1)])
    assert_includes get("/documents/#{id}").body, "Quy định nghỉ phép.pdf"
  end

  def test_delete_removes_row_and_uploaded_file
    assert_equal 303, upload.status
    doc = @store.documents.fetch(0)
    res = post_form("/documents/#{doc.id}/delete", tenant_id: "nus")
    assert_equal 303, res.status
    assert_empty @store.documents
    assert_empty uploads
  end

  def test_delete_never_removes_a_file_outside_uploads
    seed = File.join(@dir, "seed.pdf")
    outside = File.join(Dir.mktmpdir, "o.pdf")
    [seed, outside].each { |f| File.write(f, "x") }
    FileUtils.mkdir_p(File.join(@dir, "uploads", "nus")) # so the containment check itself is exercised
    a = add("seed.pdf", path: seed)
    b = add("o.pdf", path: outside, title: "o")
    [a, b].each { |id| assert_equal 303, post_form("/documents/#{id}/delete", tenant_id: "nus").status }
    assert_empty @store.documents
    assert File.exist?(seed) && File.exist?(outside)
  ensure
    FileUtils.remove_entry(File.dirname(outside))
  end

  def test_delete_other_tenant_is_404_and_keeps_data
    id = add("a.pdf")
    assert_equal 404, post_form("/documents/#{id}/delete", tenant_id: "acme").status
    assert_equal 400, post_form("/documents/#{id}/delete", tenant_id: "evil").status
    assert_equal 1, @store.documents.size
  end

  def test_delete_origin_check
    id = add("a.pdf")
    assert_equal 403, post_form("/documents/#{id}/delete", tenant_id: "nus", env: { "HTTP_ORIGIN" => "http://evil.example" }).status
    assert_equal 1, @store.documents.size
  end
end
