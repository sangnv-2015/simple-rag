module StoreContract
  def v(i)
    Array.new(Rag::EMBED_DIM, 0.0).tap { |a| a[i] = 1.0 }
  end

  def page(n, **o)
    Rag::Page.new(number: n, raw_text: "raw#{n}", markdown: "md#{n}", readable: true, fallback: false, **o)
  end

  def chunk(pg, pos, text, vec)
    Rag::Chunk.new(page: pg, position: pos, text: text, embedding: vec)
  end

  def test_migrate_is_idempotent
    store = make_store
    store.migrate!
    store.migrate!
  end

  def test_start_then_find_shows_processing
    store = make_store
    store.start_document(filename: "a.pdf", sha256: "h")
    doc = store.find_document("a.pdf")
    assert_equal "processing", doc.status
    assert_equal "h", doc.sha256
    assert_nil store.find_document("zzz.pdf")
  end

  def test_finish_stores_pages_chunks_and_counts
    store = make_store
    id = store.start_document(filename: "a.pdf", sha256: "h")
    store.finish_document(id, pages: [page(1), page(2)],
      chunks: [chunk(1, 0, "x", v(0)), chunk(1, 1, "y", v(1)), chunk(2, 0, "z", v(2))])
    docs = store.documents
    assert_equal 1, docs.size
    d = docs.first
    assert_equal ["a.pdf", "done", 2, 3], [d.filename, d.status, d.page_count, d.chunk_count]
  end

  def test_start_again_replaces_old_data
    store = make_store
    id = store.start_document(filename: "a.pdf", sha256: "h")
    store.finish_document(id, pages: [page(1)], chunks: [chunk(1, 0, "x", v(0))])
    store.start_document(filename: "a.pdf", sha256: "h2")
    assert_equal [], store.pages("a.pdf")
    assert_equal 1, store.documents.size
    assert_equal "processing", store.find_document("a.pdf").status
    assert_equal [], store.search(v(0), 5)
  end

  def test_fail_sets_error_status_and_message
    store = make_store
    id = store.start_document(filename: "a.pdf", sha256: "h")
    assert_nil store.fail_document(id, "boom")
    doc = store.find_document("a.pdf")
    assert_equal ["error", "boom"], [doc.status, doc.error]
  end

  def test_search_nearest_first_with_file_and_page
    store = make_store
    id = store.start_document(filename: "a.pdf", sha256: "h")
    store.finish_document(id, pages: [page(1), page(2)],
      chunks: [chunk(1, 0, "one", v(0)), chunk(2, 0, "two", v(1))])
    hit = store.search(v(1), 1).first
    assert_equal ["a.pdf", 2, "two"], [hit.filename, hit.page, hit.text]
    assert_in_delta 0.0, hit.distance, 1e-6
    d = store.search(v(0), 5).map(&:distance)
    assert_equal 2, d.size
    assert_equal d.sort, d
  end

  def test_search_on_empty_store_returns_empty
    assert_equal [], make_store.search(v(0), 3)
  end

  def test_pages_returns_raw_markdown_and_flags_in_order
    store = make_store
    id = store.start_document(filename: "a.pdf", sha256: "h")
    pages = [
      Rag::Page.new(number: 2, raw_text: "r2", markdown: nil, readable: false, fallback: false),
      Rag::Page.new(number: 1, raw_text: "r1", markdown: "m1", readable: true, fallback: true)
    ]
    store.finish_document(id, pages: pages, chunks: [])
    got = store.pages("a.pdf")
    assert_equal [1, 2], got.map(&:number)
    assert_equal ["r1", "m1", true, true], [got[0].raw_text, got[0].markdown, got[0].readable, got[0].fallback]
    assert_nil got[1].markdown
    assert_equal [false, false], [got[1].readable, got[1].fallback]
    assert_equal [], store.pages("nope.pdf")
  end

  def test_documents_ordered_by_filename
    store = make_store
    %w[b.pdf a.pdf c.pdf].each { |f| store.start_document(filename: f, sha256: "h") }
    assert_equal %w[a.pdf b.pdf c.pdf], store.documents.map(&:filename)
  end

  def test_search_honours_k
    store = make_store
    id = store.start_document(filename: "a.pdf", sha256: "h")
    store.finish_document(id, pages: [page(1)], chunks: [chunk(1, 0, "x", v(0)), chunk(1, 1, "y", v(1))])
    assert_equal 1, store.search(v(1), 1).size
  end

  def test_search_ignores_unfinished_documents
    store = make_store
    store.finish_document(store.start_document(filename: "ok.pdf", sha256: "h"),
      pages: [page(1)], chunks: [chunk(1, 0, "ok", v(0))])
    store.start_document(filename: "busy.pdf", sha256: "h")
    bad = store.start_document(filename: "bad.pdf", sha256: "h")
    store.finish_document(bad, pages: [page(1)], chunks: [chunk(1, 0, "bad", v(0))])
    assert_equal %w[bad.pdf ok.pdf], store.search(v(0), 10).map(&:filename).sort
    store.fail_document(bad, "boom")
    assert_equal ["ok.pdf"], store.search(v(0), 10).map(&:filename)
  end

  def test_nul_bytes_are_stripped
    store = make_store
    id = store.start_document(filename: "a.pdf", sha256: "h")
    store.finish_document(id, pages: [Rag::Page.new(number: 1, raw_text: "a\u0000b", markdown: nil, readable: true, fallback: false)], chunks: [])
    assert_equal "ab", store.pages("a.pdf").first.raw_text
  end

  def test_fail_on_missing_id_is_a_noop
    assert_nil make_store.fail_document(999, "x")
  end
end
