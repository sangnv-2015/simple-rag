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
    store.start_document(**TestMeta.attrs("a.pdf"))
    doc = by_name(store, "a.pdf")
    assert_equal "processing", doc.status
    assert_equal "h", doc.sha256
    assert_nil by_name(store, "zzz.pdf")
  end

  def test_metadata_roundtrips_with_date_objects
    store = make_store
    id = store.start_document(**TestMeta.attrs("a.pdf", title: "Policy", version: 3,
      valid_from: Date.new(2026, 1, 2), valid_to: Date.new(2026, 12, 31)))
    d = store.document(id)
    assert_equal ["nus", "Policy", 3, Date.new(2026, 1, 2), Date.new(2026, 12, 31), "/x/a.pdf", "a.pdf"],
      [d.tenant_id, d.title, d.version, d.valid_from, d.valid_to, d.path, d.filename]
    assert_kind_of Date, d.valid_from
  end

  def test_find_document_by_triple
    store = make_store
    id = store.start_document(**TestMeta.attrs("a.pdf", title: "T", version: 2))
    assert_equal id, store.find_document(tenant_id: "nus", title: "T", version: 2).id
    assert_nil store.find_document(tenant_id: "nus", title: "T", version: 1)
    assert_nil store.find_document(tenant_id: "acme", title: "T", version: 2)
  end

  def test_same_triple_replaces_other_version_coexists
    store = make_store
    a = store.start_document(**TestMeta.attrs("a.pdf", title: "T", version: 1))
    store.finish_document(a, pages: [page(1)], chunks: [chunk(1, 0, "x", v(0))])
    store.start_document(**TestMeta.attrs("b.pdf", title: "T", version: 2))
    b = store.start_document(**TestMeta.attrs("a2.pdf", title: "T", version: 1))
    assert_equal [], store.pages(b)
    assert_nil store.document(a)
    assert_equal [2, 1], store.documents.map(&:version)
    assert_equal "processing", store.document(b).status
  end

  def test_finish_stores_pages_chunks_and_counts
    store = make_store
    id = store.start_document(**TestMeta.attrs("a.pdf"))
    store.finish_document(id, pages: [page(1), page(2)],
      chunks: [chunk(1, 0, "x", v(0)), chunk(1, 1, "y", v(1)), chunk(2, 0, "z", v(2))])
    docs = store.documents
    assert_equal 1, docs.size
    d = docs.first
    assert_equal ["a.pdf", "done", 2, 3], [d.filename, d.status, d.page_count, d.chunk_count]
  end

  def test_start_again_replaces_old_data
    store = make_store
    id = store.start_document(**TestMeta.attrs("a.pdf"))
    store.finish_document(id, pages: [page(1)], chunks: [chunk(1, 0, "x", v(0))])
    id2 = store.start_document(**TestMeta.attrs("a.pdf", sha256: "h2"))
    assert_equal [], store.pages(id2)
    assert_equal 1, store.documents.size
    assert_equal "processing", by_name(store, "a.pdf").status
    assert_equal [], store.search(v(0), 5, tenant_id: "nus")
  end

  def test_fail_sets_error_status_and_message
    store = make_store
    id = store.start_document(**TestMeta.attrs("a.pdf"))
    assert_nil store.fail_document(id, "boom")
    doc = by_name(store, "a.pdf")
    assert_equal ["error", "boom"], [doc.status, doc.error]
  end

  def test_search_nearest_first_with_file_and_page
    store = make_store
    id = store.start_document(**TestMeta.attrs("a.pdf"))
    store.finish_document(id, pages: [page(1), page(2)],
      chunks: [chunk(1, 0, "one", v(0)), chunk(2, 0, "two", v(1))])
    hit = store.search(v(1), 1, tenant_id: "nus").first
    assert_equal ["a.pdf", 2, "two"], [hit.filename, hit.page, hit.text]
    assert_in_delta 0.0, hit.distance, 1e-6
    d = store.search(v(0), 5, tenant_id: "nus").map(&:distance)
    assert_equal 2, d.size
    assert_equal d.sort, d
  end

  def test_search_on_empty_store_returns_empty
    assert_equal [], make_store.search(v(0), 3, tenant_id: "nus")
  end

  def test_pages_returns_raw_markdown_and_flags_in_order
    store = make_store
    id = store.start_document(**TestMeta.attrs("a.pdf"))
    pages = [
      Rag::Page.new(number: 2, raw_text: "r2", markdown: nil, readable: false, fallback: false),
      Rag::Page.new(number: 1, raw_text: "r1", markdown: "m1", readable: true, fallback: true)
    ]
    store.finish_document(id, pages: pages, chunks: [])
    got = store.pages(id)
    assert_equal [1, 2], got.map(&:number)
    assert_equal ["r1", "m1", true, true], [got[0].raw_text, got[0].markdown, got[0].readable, got[0].fallback]
    assert_nil got[1].markdown
    assert_equal [false, false], [got[1].readable, got[1].fallback]
    assert_equal [], store.pages(999)
  end

  def test_documents_ordered_by_title_then_version_desc
    store = make_store
    store.start_document(**TestMeta.attrs("b.pdf"))
    store.start_document(**TestMeta.attrs("a1.pdf", title: "a", version: 1))
    store.start_document(**TestMeta.attrs("a2.pdf", title: "a", version: 2))
    store.start_document(**TestMeta.attrs("c.pdf", tenant_id: "acme"))
    assert_equal %w[a2.pdf a1.pdf b.pdf c.pdf], store.documents.map(&:filename)
    assert_equal %w[a2.pdf a1.pdf b.pdf], store.documents(tenant_id: "nus").map(&:filename)
  end

  def test_search_honours_k
    store = make_store
    id = store.start_document(**TestMeta.attrs("a.pdf"))
    store.finish_document(id, pages: [page(1)], chunks: [chunk(1, 0, "x", v(0)), chunk(1, 1, "y", v(1))])
    assert_equal 1, store.search(v(1), 1, tenant_id: "nus").size
  end

  def test_search_ignores_unfinished_documents
    store = make_store
    store.finish_document(store.start_document(**TestMeta.attrs("ok.pdf")),
      pages: [page(1)], chunks: [chunk(1, 0, "ok", v(0))])
    store.start_document(**TestMeta.attrs("busy.pdf"))
    bad = store.start_document(**TestMeta.attrs("bad.pdf"))
    store.finish_document(bad, pages: [page(1)], chunks: [chunk(1, 0, "bad", v(0))])
    assert_equal %w[bad.pdf ok.pdf], store.search(v(0), 10, tenant_id: "nus").map(&:filename).sort
    store.fail_document(bad, "boom")
    assert_equal ["ok.pdf"], store.search(v(0), 10, tenant_id: "nus").map(&:filename)
  end

  def done(name, text = "x", vec = v(0), **o)
    id = store_for_helpers.start_document(**TestMeta.attrs(name, **o))
    store_for_helpers.finish_document(id, pages: [page(1)], chunks: [chunk(1, 0, text, vec)])
    id
  end

  def store_for_helpers = (@helper_store ||= make_store)

  def test_search_filters_tenant
    s = store_for_helpers
    done("n.pdf")
    done("a.pdf", tenant_id: "acme")
    assert_equal ["n.pdf"], s.search(v(0), 10, tenant_id: "nus").map(&:filename)
    assert_equal ["a.pdf"], s.search(v(0), 10, tenant_id: "acme").map(&:filename)
    assert_equal [], s.search(v(0), 10, tenant_id: "other")
  end

  def test_search_document_ids_filter
    s = store_for_helpers
    a = done("a.pdf")
    b = done("b.pdf")
    foreign = done("c.pdf", tenant_id: "acme")
    assert_equal ["a.pdf"], s.search(v(0), 10, tenant_id: "nus", document_ids: [a]).map(&:filename)
    assert_equal %w[a.pdf b.pdf], s.search(v(0), 10, tenant_id: "nus", document_ids: [a, b]).map(&:filename).sort
    assert_equal [], s.search(v(0), 10, tenant_id: "nus", document_ids: [foreign])
    assert_equal [], s.search(v(0), 10, tenant_id: "nus", document_ids: [99_999])
    assert_equal %w[a.pdf b.pdf], s.search(v(0), 10, tenant_id: "nus", document_ids: []).map(&:filename).sort
  end

  def test_search_validity_is_inclusive
    s = store_for_helpers
    done("a.pdf", valid_from: Date.new(2026, 3, 1), valid_to: Date.new(2026, 3, 31))
    hit = ->(day) { s.search(v(0), 5, tenant_id: "nus", on: day).size }
    assert_equal 0, hit.call(Date.new(2026, 2, 28))
    assert_equal 1, hit.call(Date.new(2026, 3, 1))
    assert_equal 1, hit.call(Date.new(2026, 3, 31))
    assert_equal 0, hit.call(Date.new(2026, 4, 1))
  end

  def test_search_excludes_expired_and_processing_and_error
    s = store_for_helpers
    done("ok.pdf", title: "ok")
    done("old.pdf", title: "t", version: 1)
    done("new.pdf", title: "t", version: 2)
    s.start_document(**TestMeta.attrs("busy.pdf"))
    bad = done("bad.pdf")
    s.fail_document(bad, "boom")
    assert_equal %w[new.pdf ok.pdf], s.search(v(0), 10, tenant_id: "nus").map(&:filename).sort
  end

  def test_search_hit_has_ids_title_version_and_score
    s = store_for_helpers
    id = done("a.pdf", "hello", v(2), title: "Policy", version: 4)
    hit = s.search(v(2), 1, tenant_id: "nus").first
    assert_equal id, hit.document_id
    assert_equal ["Policy", 4], [hit.title, hit.version]
    assert_equal s.chunks(id).first.id, hit.chunk_id
    assert_in_delta 1.0, hit.score, 1e-6
  end

  def test_finish_expires_lower_versions
    s = store_for_helpers
    v1 = done("a1.pdf", title: "T", version: 1, valid_from: Date.new(2026, 1, 1), valid_to: Date.new(2026, 12, 31))
    done("a2.pdf", title: "T", version: 2, valid_from: Date.new(2026, 6, 1), valid_to: Date.new(2027, 12, 31))
    d = s.document(v1)
    assert_equal ["expired", Date.new(2026, 6, 1)], [d.status, d.valid_to]
    assert_equal 1, s.chunks(v1).size
    # valid_to already earlier than new.valid_from stays
    v3 = done("a3.pdf", title: "U", version: 1, valid_from: Date.new(2026, 1, 1), valid_to: Date.new(2026, 2, 1))
    done("a4.pdf", title: "U", version: 2, valid_from: Date.new(2026, 6, 1), valid_to: Date.new(2027, 1, 1))
    assert_equal Date.new(2026, 2, 1), s.document(v3).valid_to
  end

  def test_versions_compare_as_integers
    s = store_for_helpers
    v2 = done("a2.pdf", title: "T", version: 2)
    done("a10.pdf", title: "T", version: 10)
    assert_equal "expired", s.document(v2).status
  end

  def test_lower_version_finishing_after_higher_is_expired_itself
    s = store_for_helpers
    hi = done("hi.pdf", title: "T", version: 5)
    lo = s.start_document(**TestMeta.attrs("lo.pdf", title: "T", version: 3, valid_to: Date.new(2030, 1, 1)))
    s.finish_document(lo, pages: [page(1)], chunks: [chunk(1, 0, "x", v(0))])
    d = s.document(lo)
    assert_equal ["expired", Date.new(2030, 1, 1)], [d.status, d.valid_to]
    assert_equal "done", s.document(hi).status
  end

  def test_other_tenant_same_title_not_expired
    s = store_for_helpers
    a = done("a.pdf", title: "T", version: 1, tenant_id: "acme")
    done("b.pdf", title: "T", version: 2)
    assert_equal "done", s.document(a).status
  end

  def test_delete_does_not_revive_older_version
    s = store_for_helpers
    v1 = done("a1.pdf", title: "T", version: 1)
    v2 = done("a2.pdf", title: "T", version: 2)
    s.delete_document(v2, tenant_id: "nus")
    assert_equal "expired", s.document(v1).status
    assert_equal [], s.search(v(0), 5, tenant_id: "nus")
  end

  def test_delete_document_returns_doc_cascades_and_respects_tenant
    s = store_for_helpers
    id = done("a.pdf")
    assert_nil s.delete_document(id, tenant_id: "acme")
    assert_equal 1, s.chunks(id).size
    gone = s.delete_document(id, tenant_id: "nus")
    assert_equal ["a.pdf", id], [gone.filename, gone.id]
    assert_nil s.document(id)
    assert_equal [], s.pages(id)
    assert_equal [], s.chunks(id)
    assert_nil s.delete_document(id, tenant_id: "nus")
  end

  def test_document_lookup_by_id_scoped_by_tenant
    s = store_for_helpers
    id = done("a.pdf")
    assert_equal id, s.document(id).id
    assert_equal id, s.document(id, tenant_id: "nus").id
    assert_nil s.document(id, tenant_id: "acme")
    assert_nil s.document(999)
  end

  def test_chunks_returns_ids_in_order
    s = store_for_helpers
    id = s.start_document(**TestMeta.attrs("a.pdf"))
    s.finish_document(id, pages: [page(1), page(2)],
      chunks: [chunk(1, 0, "x", v(0)), chunk(1, 1, "y", v(1)), chunk(2, 0, "z", v(2))])
    got = s.chunks(id)
    assert_equal %w[x z y], got.map(&:text) # ordered by position, then id
    assert_equal [1, 2, 1], got.map(&:page)
    assert_equal [0, 0, 1], got.map(&:position)
    assert_equal got.size, got.map(&:id).uniq.size
    assert(got.all? { |c| c.embedding.nil? })
  end

  def test_log_query_roundtrip
    s = store_for_helpers
    assert_nil s.log_query(tenant_id: "nus", question: "q?", standalone: nil, document_ids: [1, 2],
      retrieved_chunk_ids: [3, 4], scores: [0.5, 0.25], status: "answered", answer: "a", cited_chunk_ids: [3], source: "web")
    assert_nil s.log_query(tenant_id: "acme", question: "q2", standalone: "sa", document_ids: [],
      retrieved_chunk_ids: [], scores: [], status: "not_enough_information", answer: nil, cited_chunk_ids: [], source: "api")
    rows = s.query_logs
    assert_equal %w[q2 q?], rows.map { |r| r["question"] }
    r = rows.last
    assert_equal ["nus", nil, [1, 2], [3, 4], [0.5, 0.25], "answered", "a", [3], "web"],
      r.values_at("tenant_id", "standalone", "document_ids", "retrieved_chunk_ids", "scores", "status", "answer", "cited_chunk_ids", "source")
    assert_equal "sa", rows.first["standalone"]
    assert_equal [], rows.first["document_ids"]
    assert_equal 1, s.query_logs(limit: 1).size
  end

  def test_nul_bytes_are_stripped
    store = make_store
    id = store.start_document(**TestMeta.attrs("a.pdf"))
    store.finish_document(id, pages: [Rag::Page.new(number: 1, raw_text: "a\u0000b", markdown: nil, readable: true, fallback: false)], chunks: [])
    assert_equal "ab", store.pages(id).first.raw_text
  end

  def test_fail_on_missing_id_is_a_noop
    assert_nil make_store.fail_document(999, "x")
  end
end
