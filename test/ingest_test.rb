require "test_helper"
require "tmpdir"

class IngestTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = FakeStore.new
    @embedder = FakeEmbedder.new
    # Echo the page text under a heading so numbers survive restructuring.
    @llm = FakeLLM.new { |m| "# " + m.last[:content][/^---\n(.*)\n---\n\z/m, 1] }
  end

  def teardown = FileUtils.remove_entry(@dir)

  def page(n, text = "Trang #{n} nội dung số #{n}00", readable: true)
    Rag::Page.new(number: n, raw_text: text, markdown: nil, readable: readable, fallback: false)
  end

  def write(name, body = "x") = File.join(@dir, name).tap { |p| File.write(p, body) }

  def ingest(files, opts = {})
    @extractor = FakeExtractor.new(files)
    Rag::Ingest.new(llm: opts.fetch(:llm, @llm), embedder: @embedder, store: opts.fetch(:store, @store), extractor: @extractor)
  end

  def test_ingests_file_and_stores_pages_chunks_with_page_numbers
    path = write("a.pdf")
    report = ingest("a.pdf" => [page(1), page(2)]).call(path)
    assert_equal ["a.pdf"], report.ok
    refute report.failed?
    assert_equal "done", @store.find_document("a.pdf").status
    hits = @store.search(@embedder.embed_query("nội dung"), 10)
    assert_equal 2, hits.size
    assert(hits.all? { |h| (1..2).cover?(h.page) })
    assert_equal 1, @embedder.inputs.size
    assert_equal hits.map(&:text).sort, @embedder.inputs.first.sort
  end

  def test_unchanged_file_is_skipped_without_llm_or_extractor_calls
    path = write("a.pdf")
    ing = ingest("a.pdf" => [page(1)])
    ing.call(path)
    llm_n, ext_n = @llm.calls.size, @extractor.calls.size
    report = ing.call(path)
    assert_equal ["a.pdf"], report.skipped
    assert_equal llm_n, @llm.calls.size
    assert_equal ext_n, @extractor.calls.size
  end

  def test_changed_file_replaces_old_data
    path = write("a.pdf", "v1")
    ingest("a.pdf" => [page(1, "Bản cũ 111")]).call(path)
    File.write(path, "v2")
    ingest("a.pdf" => [page(1, "Bản mới 222")]).call(path)
    assert_equal 1, @store.documents.size
    texts = @store.search(@embedder.embed_query("bản"), 10).map(&:text).join
    assert_includes texts, "Bản mới 222"
    refute_includes texts, "Bản cũ"
  end

  def test_failed_file_does_not_stop_the_batch
    write("bad.pdf")
    write("good.pdf")
    err = Rag::Extract::Error.new("File hỏng")
    report = ingest("bad.pdf" => err, "good.pdf" => [page(1)]).call(@dir)
    assert_equal [["bad.pdf", "File hỏng"]], report.failed
    assert_equal ["good.pdf"], report.ok
    assert report.failed?
    doc = @store.find_document("bad.pdf")
    assert_equal "error", doc.status
    assert_equal "File hỏng", doc.error
    assert_empty @store.pages("bad.pdf")
    assert_includes report.summary, "OK: good.pdf"
    assert_includes report.summary, "Lỗi: bad.pdf — File hỏng"
  end

  def test_unreadable_page_is_marked_and_not_sent_to_llm
    path = write("a.pdf")
    pages = [page(1), page(2, "", readable: false), page(3)]
    ingest("a.pdf" => pages).call(path)
    stored = @store.pages("a.pdf")
    assert_equal [true, false, true], stored.map(&:readable)
    assert_nil stored[1].markdown
    assert_equal 2, @llm.calls.size
    assert_equal [1, 3], @store.search(@embedder.embed_query("trang"), 10).map(&:page).sort
  end

  def test_file_with_only_unreadable_pages_fails_with_scan_message
    path = write("a.pdf")
    report = ingest("a.pdf" => [page(1, "", readable: false)]).call(path)
    assert_equal [["a.pdf", "file scan, không đọc được"]], report.failed
  end

  def test_page_with_dropped_number_uses_raw_text_for_chunks
    path = write("a.pdf")
    llm = FakeLLM.new { "# Tổng cộng" }
    store = FakeStore.new
    report = ingest({ "a.pdf" => [page(1, "Tổng 1.250.000 đồng")] }, store: store, llm: llm).call(path)
    assert_equal ["a.pdf"], report.ok
    p = store.pages("a.pdf").first
    assert p.fallback
    assert_equal "# Tổng cộng", p.markdown
    assert_includes store.search(@embedder.embed_query("tổng"), 5).first.text, "1.250.000"
  end

  def test_error_status_with_same_hash_is_retried_not_skipped
    path = write("a.pdf")
    ingest("a.pdf" => Rag::Extract::Error.new("lỗi")).call(path)
    report = ingest("a.pdf" => [page(1)]).call(path)
    assert_equal ["a.pdf"], report.ok
    assert_empty report.skipped
    assert_equal "done", @store.find_document("a.pdf").status
  end

  def test_llm_error_midway_stores_no_pages_or_chunks
    path = write("a.pdf")
    n = 0
    llm = FakeLLM.new { |m| (n += 1) == 2 ? Rag::DeepSeek::Error.new("DeepSeek bận") : "# ok 1" }
    report = ingest({ "a.pdf" => [page(1, "ok 1"), page(2, "ok 2")] }, llm: llm).call(path)
    assert_equal [["a.pdf", "DeepSeek bận"]], report.failed
    doc = @store.find_document("a.pdf")
    assert_equal "error", doc.status
    assert_equal "DeepSeek bận", doc.error
    assert_equal [], @store.pages("a.pdf")
    assert_equal 0, doc.chunk_count
  end

  def test_directory_takes_only_pdf_and_docx_case_insensitive_sorted
    %w[b.docx c.txt a.PDF].each { |n| write(n) }
    report = ingest("a.PDF" => [page(1)], "b.docx" => [page(1)]).call(@dir)
    assert_equal ["a.PDF", "b.docx"], report.ok
    assert_empty report.failed
  end

  def test_empty_directory_reports_no_files
    write("c.txt")
    report = ingest({}).call(@dir)
    assert_empty report.ok
    assert_equal "Không có file .pdf/.docx nào trong #{@dir}", report.summary
  end

  def test_single_file_path_and_unsupported_extension_path
    ok = write("a.pdf")
    txt = write("c.txt")
    ing = ingest("a.pdf" => [page(1)])
    assert_equal ["a.pdf"], ing.call(ok).ok
    assert_equal [["c.txt", "Chỉ nhận file .pdf và .docx."]], ing.call(txt).failed
  end

  def test_nfd_named_file_with_same_content_is_the_same_document
    nfc = "Quy định.pdf".unicode_normalize(:nfc)
    nfd = nfc.unicode_normalize(:nfd)
    ing = ingest(nfc => [page(1)], nfd => [page(1)])
    ing.call(write(nfc))
    report = ing.call(write(nfd, "x"))
    assert_equal [nfc], report.skipped.map { |f| f.unicode_normalize(:nfc) }
    assert_equal 1, @store.documents.size
    assert_equal nfc, @store.documents.first.filename
  end

  def test_unexpected_error_hides_message_and_logs_to_stderr
    write("a.pdf")
    write("b.pdf")
    boom = RuntimeError.new("boom /secret/path")
    report = nil
    _, err = capture_io { report = ingest("a.pdf" => boom, "b.pdf" => [page(1)]).call(@dir) }
    assert_equal [["a.pdf", "Lỗi không xác định khi xử lý file."]], report.failed
    assert_equal ["b.pdf"], report.ok
    assert_equal "Lỗi không xác định khi xử lý file.", @store.find_document("a.pdf").error
    assert_includes err, "RuntimeError"
    assert_includes err, "boom /secret/path"
    refute_includes report.summary, "secret"
  end

  def test_failure_to_record_failure_does_not_abort_the_batch
    write("a.pdf")
    write("b.pdf")
    store = FakeStore.new
    def store.fail_document(*) = raise(PG::ConnectionBad, "db down")
    report = nil
    capture_io { report = ingest({ "a.pdf" => Rag::Extract::Error.new("hỏng"), "b.pdf" => [page(1)] }, store: store).call(@dir) }
    assert_equal [["a.pdf", "hỏng"]], report.failed
    assert_equal ["b.pdf"], report.ok
  end
end
