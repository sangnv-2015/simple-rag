require "test_helper"
require "tmpdir"
require "yaml"
require "rack/mock"
require_relative "../../src/web/app"

class ApiTest < Minitest::Test
  HOST = "localhost:4567"
  TEXT = "Điều 5. Nếu hủy, bên B hoàn trả trong vòng 14 ngày kể từ ngày nhận yêu cầu."
  QUOTE = "bên B hoàn trả trong vòng 14 ngày"
  Q = "Hoàn tiền trong bao lâu?"
  ROUTES = [["GET", "/api/documents"], ["POST", "/api/documents"], ["GET", "/api/documents/1/chunks"],
            ["DELETE", "/api/documents/1"], ["POST", "/api/search"], ["POST", "/api/ask"]].freeze

  def setup
    @dir = Dir.mktmpdir
    @store = FakeStore.new
    @embedder = FakeEmbedder.new
    @worker = FakeWorker.new
    @reply = "Hoàn tiền trong 14 ngày [S1].\n<<QUOTES>>\n[S1] #{QUOTE}"
    @llm = FakeLLM.new { @reply }
  end

  def teardown = FileUtils.remove_entry(@dir)

  def app(min_score: -1.0)
    store, worker, dir = @store, @worker, @dir
    ingest = Rag::Ingest.new(llm: nil, embedder: @embedder, store: store)
    ask = Rag::Ask.new(llm: @llm, embedder: @embedder, store: store, min_score: min_score)
    retriever = Rag::Retriever.new(embedder: @embedder, store: store, k: Rag::TOP_K)
    Class.new(Web) do
      set :store, store; set :worker, worker; set :ingest, ingest; set :documents_dir, dir
      set :ask, ask; set :retriever, retriever
    end
  end

  def call(method, path, tenant: "nus", body: nil, env: {}, min_score: -1.0)
    e = { "HTTP_HOST" => HOST }
    e["HTTP_X_TENANT_ID"] = tenant if tenant
    e.merge!("CONTENT_TYPE" => "application/json", input: body.is_a?(String) ? body : JSON.generate(body)) if body
    Rack::MockRequest.new(app(min_score: min_score)).request(method, path, e.merge(env))
  end

  def json(r) = JSON.parse(r.body)

  def add(title, text = TEXT, tenant: "nus", version: 1, from: Date.new(2000, 1, 1), to: Date.new(2999, 12, 31), path: nil)
    id = @store.start_document(**TestMeta.attrs("#{title}.pdf", tenant_id: tenant, title: title, version: version,
                                                valid_from: from, valid_to: to, path: path || File.join(@dir, "uploads", tenant, "#{title}-#{version}.pdf")))
    @store.finish_document(id, pages: [], chunks: [Rag::Chunk.new(page: 2, position: 0, text: text, embedding: @embedder.embed_query(text))])
    id
  end

  def chunk_ids(r) = json(r)["chunks"].map { |c| c["chunk_id"] }

  def upload(name: "a.pdf", body: "%PDF-1.4 hi", meta: {}, tenant: "nus", env: {})
    m = { "title" => "Quy chế", "version" => "1", "valid_from" => "2026-01-01", "valid_to" => "2026-12-31" }.merge(meta)
    b = "xB"
    fields = m.map { |k, v| "--#{b}\r\nContent-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}\r\n" }.join
    payload = "#{fields}--#{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{name}\"\r\nContent-Type: application/octet-stream\r\n\r\n#{body}\r\n--#{b}--\r\n"
    call("POST", "/api/documents", tenant: tenant, env: { "CONTENT_TYPE" => "multipart/form-data; boundary=#{b}", input: payload }.merge(env))
  end

  # tenant header

  def test_bad_tenant_header_is_400_on_every_route
    ROUTES.each do |m, path|
      [nil, "", "NUS", " nus", "nus,acme", "zzz"].each do |t|
        r = call(m, path, tenant: t, body: m == "POST" ? { question: "x" } : nil)
        assert_equal 400, r.status, "#{m} #{path} tenant=#{t.inspect}"
        assert json(r)["error"]
      end
    end
  end

  # documents

  def test_list_is_scoped_and_reports_chunk_count
    add("A"); add("B", tenant: "acme")
    docs = json(call("GET", "/api/documents"))["documents"]
    assert_equal ["A"], docs.map { |d| d["title"] }
    d = docs.first
    assert_equal %w[id title version filename valid_from valid_to status error chunk_count].sort, d.keys.sort
    assert_equal [1, "done", "2000-01-01", "2999-12-31"], [d["chunk_count"], d["status"], d["valid_from"], d["valid_to"]]
  end

  def test_current_true_hides_expired_and_out_of_window
    add("Old", version: 1); add("Old", version: 2)
    add("Past", from: Date.new(2000, 1, 1), to: Date.new(2000, 12, 31))
    add("Future", from: Date.new(2998, 1, 1))
    all = json(call("GET", "/api/documents"))["documents"].map { |d| [d["title"], d["version"]] }
    assert_equal 4, all.size
    cur = json(call("GET", "/api/documents?current=true"))["documents"].map { |d| [d["title"], d["version"]] }
    assert_equal [["Old", 2]], cur
  end

  def test_chunks_and_cross_tenant_404
    id = add("A")
    c = json(call("GET", "/api/documents/#{id}/chunks"))["chunks"]
    assert_equal [[0, 2, TEXT]], c.map { |x| [x["chunk_index"], x["page"], x["text"]] }
    assert c.first["id"]
    r = call("GET", "/api/documents/#{id}/chunks", tenant: "acme")
    assert_equal [404, { "error" => "document not found" }], [r.status, json(r)]
    assert_equal 404, call("GET", "/api/documents/abc/chunks").status
  end

  def test_delete_cross_tenant_keeps_data
    id = add("A")
    r = call("DELETE", "/api/documents/#{id}", tenant: "acme")
    assert_equal [404, { "error" => "document not found" }], [r.status, json(r)]
    assert @store.document(id)
  end

  def test_delete_removes_row_and_uploaded_file_only
    FileUtils.mkdir_p(File.join(@dir, "uploads", "nus"))
    f = File.join(@dir, "uploads", "nus", "x.pdf")
    File.write(f, "x")
    id = add("A", path: f)
    r = call("DELETE", "/api/documents/#{id}")
    assert_equal [200, { "id" => id, "deleted" => true }], [r.status, json(r)]
    assert_nil @store.document(id)
    refute File.exist?(f)

    sample = File.join(@dir, "sample.pdf")
    File.write(sample, "x")
    id2 = add("B", path: sample)
    assert_equal 200, call("DELETE", "/api/documents/#{id2}").status
    assert File.exist?(sample)
  end

  def test_upload_accepts_and_enqueues
    r = upload
    assert_equal 202, r.status
    b = json(r)
    assert_equal "processing", b["status"]
    assert_equal "processing", @store.document(b["id"]).status
    assert_equal b["id"], @worker.enqueued.first.first
  end

  def test_upload_invalid_metadata_is_422_with_field
    [[{ "title" => "" }, "title"], [{ "version" => "0" }, "version"], [{ "version" => "x" }, "version"],
     [{ "valid_from" => "nope" }, "valid_from"], [{ "valid_to" => "nope" }, "valid_to"],
     [{ "valid_from" => "2027-01-01" }, "valid_to"]].each do |meta, field|
      r = upload(meta: meta)
      assert_equal 422, r.status, meta.inspect
      assert_equal "application/json", r.content_type
      b = json(r)
      assert_equal ["invalid metadata", field], [b["error"], b["field"]], meta.inspect
      assert_match(/\A[\x20-\x7e]+\z/, b["detail"], meta.inspect)
      assert_includes b["detail"], field
    end
    assert_empty @store.documents
    assert_empty @worker.enqueued
  end

  def test_upload_rejects_txt
    r = upload(name: "a.txt")
    assert_equal 422, r.status
    assert_equal "file", json(r)["field"]
    assert_equal "only .pdf and .docx files are accepted", json(r)["detail"]
    assert_empty @store.documents
  end

  # search

  def test_search_shape_scores_and_top_k
    add("A"); add("B", "Khác hẳn: quy định về nghỉ phép năm.")
    b = json(call("POST", "/api/search", body: { question: Q }))
    c = b["chunks"].first
    assert_equal %w[chunk_id content document_id page score title version], c.keys.sort
    assert_equal c["score"].round(3), c["score"]
    assert_equal 2, b["chunks"].size
    assert_equal 1, json(call("POST", "/api/search", body: { question: Q, top_k: 1 }))["chunks"].size
    assert_empty @llm.calls
  end

  def test_search_validation
    bad = [{ question: Q, top_k: 0 }, { question: Q, top_k: -1 }, { question: Q, top_k: 1000 }, { question: Q, top_k: "3" },
           { question: Q, top_k: 1.5 }, { question: Q, document_ids: ["a"] }, { question: Q, document_ids: [0] },
           { question: Q, document_ids: {} }, { question: Q, document_ids: (1..201).to_a }, { question: "  " },
           { question: 5 }, {}, { question: "x" * 2001 }]
    bad.each { |b| assert_equal 400, call("POST", "/api/search", body: b).status, b.inspect }
    ["[1]", "nope", "\"s\""].each { |b| assert_equal 400, call("POST", "/api/search", body: b).status, b }
    [call("POST", "/api/ask", body: "[]"), call("POST", "/api/ask", body: { question: "" })].each { |r| assert_equal 400, r.status }
    r = call("POST", "/api/search", body: { question: "x" * (65 * 1024) })
    assert_equal 413, r.status
    assert json(r)["error"]
  end

  # mechanical test cases

  def test_tc4_only_current_version_is_returned
    v1 = add("Quy chế", "Phiên bản cũ: hoàn tiền trong 30 ngày.", version: 1)
    v2 = add("Quy chế", "Phiên bản mới: hoàn tiền trong 14 ngày.", version: 2)
    new_chunk = @store.chunks(v2).first.id
    assert_equal [new_chunk], chunk_ids(call("POST", "/api/search", body: { question: "hoàn tiền" }))
    assert_equal [new_chunk], chunk_ids(call("POST", "/api/ask", body: { question: "hoàn tiền" }))
    refute_includes chunk_ids(call("POST", "/api/search", body: { question: "hoàn tiền", document_ids: [v1] })), @store.chunks(v1).first.id
  end

  def test_tc5_tenants_are_isolated
    n = add("Same", "nus: hoàn tiền trong 14 ngày.")
    a = add("Same", "acme: hoàn tiền trong 7 ngày.", tenant: "acme")
    assert_equal @store.chunks(n).map(&:id), chunk_ids(call("POST", "/api/search", body: { question: "hoàn tiền" }))
    assert_equal @store.chunks(a).map(&:id), chunk_ids(call("POST", "/api/search", body: { question: "hoàn tiền" }, tenant: "acme"))
    assert_equal @store.chunks(a).map(&:id), chunk_ids(call("POST", "/api/ask", body: { question: "hoàn tiền" }, tenant: "acme"))
  end

  def test_tc6_document_ids_restrict_to_selected
    a = add("A", "Hợp đồng lao động: nghỉ phép năm 12 ngày.")
    b = add("B", TEXT)
    ids = chunk_ids(call("POST", "/api/ask", body: { question: Q, document_ids: [a] }))
    assert_empty ids & @store.chunks(b).map(&:id)
    ids = chunk_ids(call("POST", "/api/search", body: { question: Q, document_ids: [a] }))
    assert_empty ids & @store.chunks(b).map(&:id)
  end

  def test_foreign_or_unknown_document_ids_never_fall_back_to_all
    add("A"); other = add("Z", tenant: "acme")
    [[other], [999]].each do |ids|
      assert_empty json(call("POST", "/api/search", body: { question: Q, document_ids: ids }))["chunks"]
      b = json(call("POST", "/api/ask", body: { question: Q, document_ids: ids }))
      assert_equal ["not_enough_information", []], [b["status"], b["chunks"]]
    end
    assert_empty @llm.calls
  end

  def test_tc7_citations_are_among_chunks_and_quotes_are_substrings
    add("A")
    r = call("POST", "/api/ask", body: { question: Q })
    b = json(r)
    assert_equal "answered", b["status"]
    assert_equal %w[chunk_id document_id n page quote title version], b["citations"].first.keys.sort
    refute_empty b["citations"]
    b["citations"].each do |c|
      chunk = b["chunks"].find { |x| x["chunk_id"] == c["chunk_id"] }
      assert chunk
      assert c["quote"]
      assert_includes Rag::Text.comparable(chunk["content"]), Rag::Text.comparable(c["quote"])
    end
  end

  def test_tc3_low_score_skips_llm_and_keeps_chunks
    add("A")
    b = json(call("POST", "/api/ask", body: { question: Q }, min_score: 2.0))
    assert_equal "not_enough_information", b["status"]
    assert_equal "Not enough information in the documents.", b["answer"]
    assert_equal [], b["citations"]
    refute_empty b["chunks"]
    assert_empty @llm.calls
  end

  def test_ask_logs_source_api
    add("A")
    call("POST", "/api/ask", body: { question: Q })
    assert_equal "api", @store.query_logs.first["source"]
  end

  def test_llm_error_is_502_and_other_errors_500
    add("A")
    @llm = FakeLLM.new { Rag::DeepSeek::Error.new("secret detail") }
    r = call("POST", "/api/ask", body: { question: Q })
    assert_equal [502, { "error" => "upstream error" }], [r.status, json(r)]
    @llm = FakeLLM.new { RuntimeError.new("boom") }
    r = call("POST", "/api/ask", body: { question: Q })
    assert_equal [500, { "error" => "internal error" }], [r.status, json(r)]
  end

  # docs and origin

  def test_openapi_lists_the_six_paths_with_tenant_header
    r = call("GET", "/api/openapi.yaml", tenant: nil)
    assert_equal 200, r.status
    spec = YAML.safe_load(r.body)
    paths = spec["paths"]
    assert_equal({ "/api/documents" => %w[get post], "/api/documents/{id}/chunks" => %w[get], "/api/documents/{id}" => %w[delete],
                   "/api/search" => %w[post], "/api/ask" => %w[post] }.transform_values(&:sort),
                 paths.transform_values { |ops| ops.keys.sort })
    paths.each do |path, ops|
      ops.each do |m, op|
        params = op["parameters"].map { |p| p["$ref"] ? spec.dig(*p["$ref"].delete_prefix("#/").split("/")) : p }
        assert params.any? { |p| p["in"] == "header" && p["name"] == "X-Tenant-Id" && p["required"] }, "#{m} #{path}"
      end
    end
  end

  def test_docs_page_pins_swagger_ui
    b = call("GET", "/api/docs", tenant: nil).body
    assert_match(%r{swagger-ui-dist@5\.\d+\.\d+/swagger-ui-bundle\.js}, b)
    assert_includes b, "/api/openapi.yaml"
    assert_equal 2, b.scan(/integrity="sha384-[A-Za-z0-9+\/=]+" crossorigin="anonymous"/).size
  end

  def test_origin_check
    add("A")
    assert_equal 200, call("POST", "/api/search", body: { question: Q }, env: { "HTTP_ORIGIN" => "http://localhost:4567" }).status
    r = call("POST", "/api/search", body: { question: Q }, env: { "HTTP_ORIGIN" => "http://evil.example" })
    assert_equal [403, "application/json", { "error" => "cross-origin request refused" }], [r.status, r.content_type, json(r)]
  end

  def test_upload_over_cap_is_english_json_413
    r = call("POST", "/api/documents", env: { "CONTENT_LENGTH" => (Rag::MAX_UPLOAD_BYTES + 2 * 1024 * 1024).to_s,
                                              "CONTENT_TYPE" => "multipart/form-data; boundary=x", input: "" })
    assert_equal [413, "application/json", { "error" => "request body too large" }], [r.status, r.content_type, json(r)]
  end

  def test_unknown_api_path_is_json_404
    r = call("GET", "/api/zzz")
    assert_equal [404, "application/json", { "error" => "not found" }], [r.status, r.content_type, json(r)]
  end
end
