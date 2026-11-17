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

  def meta(**o) = Rag::Meta.new(tenant_id: "nus", title: "T", version: 1, valid_from: Date.new(2026, 1, 1), valid_to: Date.new(2099, 12, 31), **o)

  def metas(*names) = names.to_h { |n| [Rag::Text.nfc(n), meta(title: n)] }

  def write(name, body = "x") = File.join(@dir, name).tap { |p| File.write(p, body) }

  # "structure" by default: the older tests assert one embed call and Chunker.split output; semantic is the real default.
  def ingest(files, opts = {})
    @extractor = FakeExtractor.new(files)
    Rag::Ingest.new(llm: opts.fetch(:llm, @llm), embedder: @embedder, store: opts.fetch(:store, @store), extractor: @extractor,
                    chunking: opts.fetch(:chunking, "structure"))
  end

  def test_ingests_file_and_stores_pages_chunks_with_page_numbers
    path = write("a.pdf")
    report = ingest("a.pdf" => [page(1), page(2)]).call(path, meta)
    assert_equal ["a.pdf"], report.ok
    refute report.failed?
    assert_equal "done", by_name(@store, "a.pdf").status
    hits = @store.search(@embedder.embed_query("nội dung"), 10, tenant_id: "nus")
    assert_equal 2, hits.size
    assert(hits.all? { |h| (1..2).cover?(h.page) })
    assert_equal 1, @embedder.inputs.size
    assert_equal hits.map(&:text).sort, @embedder.inputs.first.sort
  end

  def test_unchanged_file_is_skipped_without_llm_or_extractor_calls
    path = write("a.pdf")
    ing = ingest("a.pdf" => [page(1)])
    ing.call(path, meta)
    llm_n, ext_n = @llm.calls.size, @extractor.calls.size
    report = ing.call(path, meta)
    assert_equal ["a.pdf"], report.skipped
    assert_equal llm_n, @llm.calls.size
    assert_equal ext_n, @extractor.calls.size
  end

  def test_changed_file_replaces_old_data
    path = write("a.pdf", "v1")
    ingest("a.pdf" => [page(1, "Bản cũ 111")]).call(path, meta)
    File.write(path, "v2")
    ingest("a.pdf" => [page(1, "Bản mới 222")]).call(path, meta)
    assert_equal 1, @store.documents.size
    texts = @store.search(@embedder.embed_query("bản"), 10, tenant_id: "nus").map(&:text).join
    assert_includes texts, "Bản mới 222"
    refute_includes texts, "Bản cũ"
  end

  def test_failed_file_does_not_stop_the_batch
    write("bad.pdf")
    write("good.pdf")
    err = Rag::Extract::Error.new("File hỏng")
    report = ingest("bad.pdf" => err, "good.pdf" => [page(1)]).call(@dir, metas(*Dir.children(@dir)))
    assert_equal [["bad.pdf", "File hỏng"]], report.failed
    assert_equal ["good.pdf"], report.ok
    assert report.failed?
    doc = by_name(@store, "bad.pdf")
    assert_equal "error", doc.status
    assert_equal "File hỏng", doc.error
    assert_empty @store.pages(doc.id)
    assert_includes report.summary, "OK: good.pdf"
    assert_includes report.summary, "Lỗi: bad.pdf — File hỏng"
  end

  def test_too_many_pages_fails_before_any_llm_call
    path = write("a.pdf")
    pages = (1..Rag::MAX_PAGES + 1).map { |n| page(n) }
    report = ingest("a.pdf" => pages).call(path, meta)
    assert_equal [["a.pdf", "Tài liệu quá dài (tối đa 200 trang)."]], report.failed
    assert_empty @llm.calls
    assert_equal "error", by_name(@store, "a.pdf").status
  end

  def test_exactly_max_pages_is_accepted
    path = write("a.pdf")
    report = ingest("a.pdf" => (1..Rag::MAX_PAGES).map { |n| page(n, "Trang #{n} nội dung", readable: n == 1) }).call(path, meta)
    assert_equal ["a.pdf"], report.ok
  end

  def test_oversized_page_skips_the_llm_and_is_chunked_from_raw_text
    path = write("a.pdf")
    long = ("Điều khoản dài. " * 2000)[0, Rag::MAX_PAGE_CHARS + 1]
    ingest("a.pdf" => [page(1, long), page(2)]).call(path, meta)
    assert_equal 1, @llm.calls.size # only page 2
    stored = @store.pages(by_name(@store, "a.pdf").id)
    assert_equal [true, false], stored.map(&:fallback)
    assert_nil stored[0].markdown
    texts = @store.search(@embedder.embed_query("điều khoản"), 100, tenant_id: "nus").select { |h| h.page == 1 }.map(&:text)
    assert_operator texts.size, :>, 1
    assert_equal Rag::Chunker.split(long), texts.sort_by { |t| Rag::Chunker.split(long).index(t) || 0 }
  end

  def test_unreadable_page_is_marked_and_not_sent_to_llm
    path = write("a.pdf")
    pages = [page(1), page(2, "", readable: false), page(3)]
    ingest("a.pdf" => pages).call(path, meta)
    stored = @store.pages(by_name(@store, "a.pdf").id)
    assert_equal [true, false, true], stored.map(&:readable)
    assert_nil stored[1].markdown
    assert_equal 2, @llm.calls.size
    assert_equal [1, 3], @store.search(@embedder.embed_query("trang"), 10, tenant_id: "nus").map(&:page).sort
  end

  def test_file_with_only_unreadable_pages_fails_with_scan_message
    path = write("a.pdf")
    report = ingest("a.pdf" => [page(1, "", readable: false)]).call(path, meta)
    assert_equal [["a.pdf", "file scan, không đọc được"]], report.failed
  end

  def test_page_with_dropped_number_uses_raw_text_for_chunks
    path = write("a.pdf")
    llm = FakeLLM.new { "# Tổng cộng" }
    store = FakeStore.new
    report = ingest({ "a.pdf" => [page(1, "Tổng 1.250.000 đồng")] }, store: store, llm: llm).call(path, meta)
    assert_equal ["a.pdf"], report.ok
    p = store.pages(by_name(store, "a.pdf").id).first
    assert p.fallback
    assert_equal "# Tổng cộng", p.markdown
    assert_includes store.search(@embedder.embed_query("tổng"), 5, tenant_id: "nus").first.text, "1.250.000"
  end

  def test_error_status_with_same_hash_is_retried_not_skipped
    path = write("a.pdf")
    ingest("a.pdf" => Rag::Extract::Error.new("lỗi")).call(path, meta)
    report = ingest("a.pdf" => [page(1)]).call(path, meta)
    assert_equal ["a.pdf"], report.ok
    assert_empty report.skipped
    assert_equal "done", by_name(@store, "a.pdf").status
  end

  def test_llm_error_midway_stores_no_pages_or_chunks
    path = write("a.pdf")
    n = 0
    llm = FakeLLM.new { |m| (n += 1) == 2 ? Rag::DeepSeek::Error.new("DeepSeek bận") : "# ok 1" }
    report = ingest({ "a.pdf" => [page(1, "ok 1"), page(2, "ok 2")] }, llm: llm).call(path, meta)
    assert_equal [["a.pdf", "DeepSeek bận"]], report.failed
    doc = by_name(@store, "a.pdf")
    assert_equal "error", doc.status
    assert_equal "DeepSeek bận", doc.error
    assert_equal [], @store.pages(by_name(@store, "a.pdf").id)
    assert_equal 0, doc.chunk_count
  end

  def test_directory_takes_only_pdf_and_docx_case_insensitive_sorted
    %w[b.docx c.txt a.PDF].each { |n| write(n) }
    report = ingest("a.PDF" => [page(1)], "b.docx" => [page(1)]).call(@dir, metas(*Dir.children(@dir)))
    assert_equal ["a.PDF", "b.docx"], report.ok
    assert_empty report.failed
  end

  def test_empty_directory_reports_no_files
    write("c.txt")
    report = ingest({}).call(@dir, metas(*Dir.children(@dir)))
    assert_empty report.ok
    assert_equal "Không có file .pdf/.docx nào trong #{@dir}", report.summary
  end

  def test_single_file_path_and_unsupported_extension_path
    ok = write("a.pdf")
    txt = write("c.txt")
    ing = ingest("a.pdf" => [page(1)])
    assert_equal ["a.pdf"], ing.call(ok, meta).ok
    assert_equal [["c.txt", "Chỉ nhận file .pdf và .docx."]], ing.call(txt, meta).failed
  end

  def test_nfd_named_file_with_same_content_is_the_same_document
    nfc = "Quy định.pdf".unicode_normalize(:nfc)
    nfd = nfc.unicode_normalize(:nfd)
    ing = ingest(nfc => [page(1)], nfd => [page(1)])
    ing.call(write(nfc), meta)
    report = ing.call(write(nfd, "x"), meta)
    assert_equal [nfc], report.skipped.map { |f| f.unicode_normalize(:nfc) }
    assert_equal 1, @store.documents.size
    assert_equal nfc, @store.documents.first.filename
  end

  def test_unexpected_error_hides_message_and_logs_to_stderr
    write("a.pdf")
    write("b.pdf")
    boom = RuntimeError.new("boom /secret/path")
    report = nil
    _, err = capture_io { report = ingest("a.pdf" => boom, "b.pdf" => [page(1)]).call(@dir, metas(*Dir.children(@dir))) }
    assert_equal [["a.pdf", "Lỗi không xác định khi xử lý file."]], report.failed
    assert_equal ["b.pdf"], report.ok
    assert_equal "Lỗi không xác định khi xử lý file.", by_name(@store, "a.pdf").error
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
    capture_io { report = ingest({ "a.pdf" => Rag::Extract::Error.new("hỏng"), "b.pdf" => [page(1)] }, store: store).call(@dir, metas(*Dir.children(@dir))) }
    assert_equal [["a.pdf", "hỏng"]], report.failed
    assert_equal ["b.pdf"], report.ok
  end

  def test_prepare_then_run_stores_document_with_metadata
    path = write("a.pdf")
    ing = ingest("a.pdf" => [page(1)])
    m = meta(title: "Quy chế", version: 2)
    prep = ing.prepare(path, m)
    refute prep.skipped
    assert_equal "a.pdf", prep.filename
    assert_nil ing.run(prep.id, path)
    d = @store.document(prep.id)
    assert_equal ["done", "nus", "Quy chế", 2, Date.new(2026, 1, 1)], [d.status, d.tenant_id, d.title, d.version, d.valid_from]
  end

  def test_prepare_skips_same_sha_done_and_returns_existing_id
    path = write("a.pdf")
    ing = ingest("a.pdf" => [page(1)])
    first = ing.prepare(path, meta)
    ing.run(first.id, path)
    again = ing.prepare(path, meta)
    assert again.skipped
    assert_equal first.id, again.id
  end

  def test_prepare_same_sha_new_dates_skips_but_updates_dates
    path = write("a.pdf")
    ing = ingest("a.pdf" => [page(1)])
    first = ing.prepare(path, meta)
    ing.run(first.id, path)
    llm_n, emb_n = @llm.calls.size, @embedder.inputs.size
    again = ing.prepare(path, meta(valid_from: Date.new(2026, 3, 1), valid_to: Date.new(2027, 3, 1)))
    assert again.skipped
    assert_equal [llm_n, emb_n], [@llm.calls.size, @embedder.inputs.size]
    d = @store.document(first.id)
    assert_equal ["done", Date.new(2026, 3, 1), Date.new(2027, 3, 1)], [d.status, d.valid_from, d.valid_to]
  end

  def test_prepare_same_sha_new_dates_on_expired_version_keeps_trimmed_dates
    p1 = write("v1.pdf")
    ing = ingest("v1.pdf" => [page(1)], "v2.pdf" => [page(1)])
    ing.call(p1, meta(version: 1))
    ing.call(write("v2.pdf", "other"), meta(version: 2, valid_from: Date.new(2026, 6, 1)))
    trimmed = by_name(@store, "v1.pdf").valid_to
    assert ing.prepare(p1, meta(version: 1, valid_to: Date.new(2030, 1, 1))).skipped
    assert_equal ["expired", trimmed], by_name(@store, "v1.pdf").then { |d| [d.status, d.valid_to] }
  end

  def test_prepare_same_triple_new_sha_replaces
    path = write("a.pdf", "v1")
    ing = ingest("a.pdf" => [page(1)])
    first = ing.prepare(path, meta)
    ing.run(first.id, path)
    File.write(path, "v2")
    second = ing.prepare(path, meta)
    refute second.skipped
    refute_equal first.id, second.id
    assert_nil @store.document(first.id)
  end

  def test_prepare_rejects_bad_extension_without_creating_a_row
    err = assert_raises(Rag::Error) { ingest({}).prepare(write("c.txt"), meta) }
    assert_equal "Chỉ nhận file .pdf và .docx.", err.message
    assert_empty @store.documents
  end

  def test_file_without_metadata_is_listed_and_not_ingested
    write("x.pdf")
    report = ingest("x.pdf" => [page(1)]).call(@dir, {})
    assert_equal ["x.pdf"], report.no_metadata
    assert_includes report.summary, "Bỏ qua (thiếu metadata): x.pdf"
    refute report.failed?
    assert_empty @store.documents
  end

  def test_new_version_expires_old_version_end_to_end
    p1 = write("v1.pdf")
    p2 = write("v2.pdf", "other")
    ing = ingest("v1.pdf" => [page(1, "Bản một 111")], "v2.pdf" => [page(1, "Bản hai 222")])
    ing.call(p1, meta(version: 1))
    ing.call(p2, meta(version: 2))
    assert_equal "expired", by_name(@store, "v1.pdf").status
    assert_equal "done", by_name(@store, "v2.pdf").status
    texts = @store.search(@embedder.embed_query("bản"), 10, tenant_id: "nus").map(&:text).join
    assert_includes texts, "Bản hai 222"
    refute_includes texts, "Bản một"
  end

  def test_older_version_ingested_after_newer_is_expired
    p1 = write("v1.pdf")
    p2 = write("v2.pdf", "other")
    ing = ingest("v1.pdf" => [page(1)], "v2.pdf" => [page(1)])
    ing.call(p2, meta(version: 2))
    ing.call(p1, meta(version: 1))
    assert_equal "expired", by_name(@store, "v1.pdf").status
    assert_equal "done", by_name(@store, "v2.pdf").status
  end

  def test_run_on_deleted_document_does_not_raise
    path = write("a.pdf")
    ing = ingest("a.pdf" => [page(1)])
    prep = ing.prepare(path, meta)
    @store.delete_document(prep.id, tenant_id: "nus")
    msg = nil
    capture_io { msg = ing.run(prep.id, path) }
    assert_kind_of String, msg
    assert_empty @store.documents
  end

  def test_run_failure_returns_message_and_marks_error
    path = write("a.pdf")
    ing = ingest("a.pdf" => Rag::Extract::Error.new("File hỏng"))
    prep = ing.prepare(path, meta)
    assert_equal "File hỏng", ing.run(prep.id, path)
    assert_equal "error", @store.document(prep.id).status
  end

  def test_semantic_chunking_is_the_default_and_embeds_units_then_chunks
    path = write("a.pdf")
    @extractor = FakeExtractor.new("a.pdf" => [page(1, "Câu một. Câu hai.")])
    llm = FakeLLM.new { "# Tiêu đề\nCâu một. Câu hai." }
    ing = Rag::Ingest.new(llm: llm, embedder: @embedder, store: @store, extractor: @extractor)
    assert_equal ["a.pdf"], ing.call(path, meta).ok
    assert_equal 2, @embedder.inputs.size
    assert_equal 2, @embedder.inputs.first.size # units
  end

  def test_chunking_structure_matches_chunker_split
    path = write("a.pdf")
    text = "Câu một. Câu hai."
    ingest({ "a.pdf" => [page(1, text)] }, chunking: "structure").call(path, meta)
    assert_equal 1, @embedder.inputs.size
    assert_equal Rag::Chunker.split("# " + text), @embedder.inputs.first
  end

  def test_expired_unchanged_version_is_skipped_without_new_calls
    p1 = write("v1.pdf")
    p2 = write("v2.pdf", "other")
    ing = ingest("v1.pdf" => [page(1)], "v2.pdf" => [page(1)])
    ing.call(p1, meta(version: 1))
    ing.call(p2, meta(version: 2))
    llm_n, emb_n = @llm.calls.size, @embedder.inputs.size
    report = ing.call(@dir, "v1.pdf" => meta(version: 1), "v2.pdf" => meta(version: 2))
    assert_equal %w[v1.pdf v2.pdf], report.skipped.sort
    assert_equal [llm_n, emb_n], [@llm.calls.size, @embedder.inputs.size]
    assert_equal "expired", by_name(@store, "v1.pdf").status
  end
end
