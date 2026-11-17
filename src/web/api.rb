require "json"

# JSON API under /api (Sinatra extension). Tenant comes only from X-Tenant-Id, never defaulted.
module WebApi
  NOT_ENOUGH = "Not enough information in the documents.".freeze
  MAX_BODY = 64 * 1024
  MAX_QUESTION = 2000
  MAX_IDS = 200
  MAX_ID = 2**31 - 1
  SWAGGER = "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14".freeze
  # sha384 of the exact pinned files (recompute when the version changes)
  CSS_SRI = "sha384-wxLW6kwyHktdDGr6Pv1zgm/VGJh99lfUbzSn6HNHBENZlCN7W602k9VkGdxuFvPn".freeze
  JS_SRI = "sha384-wmyclcVGX/WhUkdkATwhaK1X1JtiNrr2EoYJ+diV3vj4v6OC5yCeSu+yW13SYJep".freeze
  SPEC = File.expand_path("openapi.yaml", __dir__)
  META_DETAIL = {
    "title" => "title must be 1 to 200 characters",
    "version" => "version must be a positive integer",
    "valid_from" => "valid_from must be a date as YYYY-MM-DD",
    "valid_to" => "valid_to must be a date as YYYY-MM-DD and not before valid_from",
    "tenant_id" => "tenant is not valid"
  }.freeze
  FILE_DETAIL = {
    "Chỉ nhận file .pdf và .docx." => "only .pdf and .docx files are accepted",
    "File quá lớn (tối đa 30 MB)." => "file is too large (max 30 MB)",
    "Tên file không hợp lệ." => "file name is not valid"
  }.freeze
  PUBLIC = ["/api/openapi.yaml", "/api/docs"].freeze

  def self.chunk(hit)
    { chunk_id: hit.chunk_id, document_id: hit.document_id, title: hit.title, version: hit.version,
      page: hit.page, score: hit.score.round(3), content: hit.text }
  end

  module Helpers
    def fail!(status, error, **extra)
      halt status, { "content-type" => "application/json" }, JSON.generate({ error: error, **extra })
    end

    def respond(data, status = 200)
      content_type :json
      halt status, JSON.generate(data)
    end

    # Unexpected errors become JSON; the class is logged, never the message.
    def api
      yield
    rescue Rag::DeepSeek::Error => e
      warn "api upstream error: #{e.class}"
      fail!(502, "upstream error")
    rescue StandardError => e
      warn "api error: #{e.class}"
      fail!(500, "internal error")
    end

    def json_body
      fail!(413, "request body too large") if request.content_length.to_i > MAX_BODY
      request.body.rewind if request.body.respond_to?(:rewind)
      raw = request.body.read(MAX_BODY + 1).to_s
      fail!(413, "request body too large") if raw.bytesize > MAX_BODY
      data = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        fail!(400, "body must be valid JSON")
      end
      fail!(400, "body must be a JSON object") unless data.is_a?(Hash)
      data
    end

    def question_of(data)
      q = data["question"]
      fail!(400, "question must be a non-blank string up to #{MAX_QUESTION} characters") unless
        q.is_a?(String) && q.valid_encoding? && !q.strip.empty? && q.size <= MAX_QUESTION
      q
    end

    def document_ids_of(data)
      ids = data["document_ids"]
      return [] if ids.nil?
      fail!(400, "document_ids must be an array of at most #{MAX_IDS} positive integers") unless
        ids.is_a?(Array) && ids.size <= MAX_IDS && ids.all? { |i| i.is_a?(Integer) && i.between?(1, MAX_ID) }
      ids
    end

    def top_k_of(data)
      k = data["top_k"]
      return Rag::TOP_K if k.nil?
      fail!(400, "top_k must be an integer between 1 and 20") unless k.is_a?(Integer) && k.between?(1, 20)
      k
    end

    def api_doc(tenant_id)
      raw = params[:id].to_s
      doc = raw.match?(/\A\d{1,9}\z/) ? settings.store.document(raw.to_i, tenant_id: tenant_id) : nil
      fail!(404, "document not found") unless doc
      doc
    end
  end

  def self.registered(app)
    app.helpers Helpers

    app.before "/api/*" do
      next if PUBLIC.include?(request.path_info)
      t = request.env["HTTP_X_TENANT_ID"]
      fail!(400, "X-Tenant-Id header is missing or unknown") unless t.is_a?(String) && Rag::TENANTS.include?(t)
      @tenant = t
    end

    app.not_found do
      next unless request.path_info.start_with?("/api/")
      next if body.is_a?(Array) ? !body.join.empty? : !body.to_s.empty? # keep bodies set by fail!(404, ...)
      content_type :json
      JSON.generate(error: "not found")
    end

    app.get("/api/openapi.yaml") do
      content_type "application/yaml; charset=utf-8"
      File.read(SPEC)
    end

    app.get("/api/docs") do
      content_type "text/html; charset=utf-8"
      <<~HTML
        <!doctype html>
        <html><head><meta charset="utf-8"><title>NUSAskify API</title>
        <link rel="stylesheet" href="#{SWAGGER}/swagger-ui.css" integrity="#{CSS_SRI}" crossorigin="anonymous"></head>
        <body><div id="ui"></div>
        <script src="#{SWAGGER}/swagger-ui-bundle.js" integrity="#{JS_SRI}" crossorigin="anonymous"></script>
        <script>SwaggerUIBundle({ url: "/api/openapi.yaml", dom_id: "#ui" });</script>
        </body></html>
      HTML
    end

    app.post "/api/documents" do
      api do
        file = params[:file]
        fail!(422, "file is required", field: "file", detail: "Upload a .pdf or .docx as multipart field 'file'.") unless
          file.is_a?(Hash) && file[:tempfile].respond_to?(:read)
        begin
          prep = accept_upload(@tenant, params, file)
        rescue Rag::Meta::Invalid => e
          fail!(422, "invalid metadata", field: e.field.to_s, detail: META_DETAIL.fetch(e.field.to_s, "metadata is not valid"))
        rescue Rag::Upload::Rejected => e
          fail!(422, "invalid file", field: "file", detail: FILE_DETAIL.fetch(e.message, "file was rejected"))
        end
        respond({ id: prep.id, status: settings.store.document(prep.id).status }, 202)
      end
    end

    app.get "/api/documents" do
      api do
        docs = settings.store.documents(tenant_id: @tenant)
        docs = docs.select(&:current?) if params[:current] == "true"
        respond(documents: docs.map do |d|
          { id: d.id, title: d.title, version: d.version, filename: d.filename, valid_from: d.valid_from.to_s,
            valid_to: d.valid_to.to_s, status: d.status, error: d.error, chunk_count: d.chunk_count }
        end)
      end
    end

    app.get "/api/documents/:id/chunks" do
      api do
        doc = api_doc(@tenant)
        respond(chunks: settings.store.chunks(doc.id).map { |c| { id: c.id, chunk_index: c.position, page: c.page, text: c.text } })
      end
    end

    app.delete "/api/documents/:id" do
      api do
        doc = api_doc(@tenant)
        fail!(404, "document not found") unless delete_document!(doc.id, @tenant)
        respond(id: doc.id, deleted: true)
      end
    end

    app.post "/api/search" do
      api do
        data = json_body
        q, ids, k = question_of(data), document_ids_of(data), top_k_of(data)
        hits = settings.retriever.call(q, tenant_id: @tenant, document_ids: ids, k: k)
        respond(chunks: hits.map { |h| WebApi.chunk(h) })
      end
    end

    app.post "/api/ask" do
      api do
        data = json_body
        q, ids = question_of(data), document_ids_of(data)
        a = settings.ask.call(q, [], tenant_id: @tenant, document_ids: ids, source: "api")
        found = a.status == "answered"
        respond(status: a.status, answer: found ? a.text : NOT_ENOUGH,
                citations: found ? a.sources.map { |s| { n: s.n, chunk_id: s.chunk_id, document_id: s.document_id, title: s.title, version: s.version, page: s.page, quote: s.quote } } : [],
                chunks: a.hits.map { |h| WebApi.chunk(h) })
      end
    end
  end
end
