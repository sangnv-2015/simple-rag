require "json"
require "sinatra/base"
require_relative "../rag"
require_relative "api"

class Web < Sinatra::Base
  FRIENDLY_ERROR = "Không thể trả lời lúc này. Vui lòng thử lại sau.".freeze
  # Errors from writing to a browser that went away: nothing to report.
  CLIENT_GONE = [IOError, Errno::EPIPE, Errno::ECONNRESET].freeze

  # Evaluated at rescue time: Puma is not loaded yet when config.ru loads this file.
  def self.client_gone?(e)
    CLIENT_GONE.any? { |c| e.is_a?(c) } || (defined?(Puma::ConnectionError) && e.is_a?(Puma::ConnectionError))
  end

  # Views must wrap every dynamic value in h(...); ERB here does not escape on its own.
  def h(text) = Rack::Utils.escape_html(text.to_s)

  # Escaped text with the quoted passage wrapped in <mark>.
  def highlight(text, quote)
    r = quote && Rag::Text.locate(text, quote)
    return h(text) unless r
    t = Rag::Text.nfc(text.to_s)
    id = %( id="hit") unless @hit # first match is the scroll target of the link's #hit
    @hit = true
    "#{h t[0...r.begin]}<mark#{id}>#{h t[r]}</mark>#{h t[r.end..]}"
  end

  set :views, File.expand_path("views", __dir__)
  # PUBLIC_HOST (comma-separated, e.g. an ngrok domain) is let in on top of localhost; unset = local only.
  # Tolerates a pasted URL ("https://x.ngrok-free.app/"): Host headers carry the bare name only.
  def self.public_hosts(raw) = raw.to_s.split(",").map { |h| h.strip.sub(%r{\A\w+://}, "").chomp("/") }.reject(&:empty?)
  PUBLIC_HOSTS = public_hosts(ENV["PUBLIC_HOST"]).freeze
  set :public_host_list, PUBLIC_HOSTS
  set :host_authorization, permitted_hosts: ["localhost", "127.0.0.1", "[::1]", *PUBLIC_HOSTS]
  use Rack::TempfileReaper
  set :show_exceptions, false
  set :ask, nil
  set :store, nil
  set :worker, nil
  set :ingest, nil
  set :retriever, nil
  set :documents_dir, nil
  set :max_upload_bytes, Rag::MAX_UPLOAD_BYTES
  register WebApi

  TOO_LARGE = "File quá lớn (tối đa 30 MB).".freeze
  MULTIPART_OVERHEAD = 1024 * 1024
  MAX_ASK_BODY = 64 * 1024
  MAX_DOCUMENT_IDS = 200
  HISTORY_TURNS = 3
  HISTORY_Q_MAX = 1000
  HISTORY_A_MAX = 2000
  BAD_REQUEST = "Yêu cầu không hợp lệ.".freeze
  ASK_TOO_LARGE = "Yêu cầu quá lớn.".freeze

  # Puma (config/puma.rb) refuses a Content-Length over 32 MB itself; below that Puma has already read
  # the body when this runs, so these checks stop the app from parsing a too-big or cross-site request.
  # Path-independent on purpose: Mustermann also matches percent-encoded paths (/%64ocuments).
  def call!(env)
    origin = env["HTTP_ORIGIN"]
    # Every method: a cross-site POST /ask would spend paid model calls. Plain navigations send no Origin.
    api = env["PATH_INFO"].to_s.start_with?("/api")
    reject = lambda do |status, vi, en|
      api ? [status, { "content-type" => "application/json" }, [JSON.generate(error: en)]] : [status, { "content-type" => "text/plain; charset=utf-8" }, [vi]]
    end
    return reject.call(403, "Yêu cầu không hợp lệ.", "cross-origin request refused") if origin && !local_origin?(origin, env)
    # Public demo = read + chat only: no auth exists, so a tunnel Host must not upload, delete or call the JSON API (POST /ask stays).
    if public_request?(env) && write_route?(env)
      return reject.call(403, "Không được phép qua địa chỉ công khai.", "write access is not available on the public host")
    end
    if env["CONTENT_LENGTH"].to_i > settings.max_upload_bytes + MULTIPART_OVERHEAD
      return reject.call(413, TOO_LARGE, "request body too large")
    end
    super
  end

  # Host must be permitted (loopback aliases allowed); scheme and port must be this request's own, so another local app is refused.
  def local_origin?(origin, env)
    u = URI.parse(origin)
    return false unless settings.host_authorization[:permitted_hosts].include?(u.host)
    own = Rack::Request.new(env)
    [u.scheme, u.port] == [own.scheme, own.port]
  rescue URI::InvalidURIError
    false
  end

  def public_request?(env)
    host = env["HTTP_HOST"].to_s.sub(/:\d+\z/, "")
    settings.public_host_list.include?(host)
  end

  # Decoded first: Mustermann also matches percent-encoded paths.
  def write_route?(env)
    return false if %w[GET HEAD].include?(env["REQUEST_METHOD"])
    path = Rack::Utils.unescape_path(env["PATH_INFO"].to_s)
    path.start_with?("/api") || path == "/documents" || path.match?(%r{\A/documents/[^/]+/delete\z})
  end

  get "/" do
    @empty = settings.store.documents.none? { |d| d.status == "done" }
    erb :ask
  end

  post "/ask" do
    # Checked here, not in call!: that one must not trust path matching.
    halt 413, ASK_TOO_LARGE if request.content_length.to_i > MAX_ASK_BODY
    request.body.rewind if request.body.respond_to?(:rewind) # Rack 3: rack.input need not be rewindable
    raw = request.body.read(MAX_ASK_BODY + 1).to_s # also caps chunked bodies without Content-Length
    halt 413, ASK_TOO_LARGE if raw.bytesize > MAX_ASK_BODY
    tenant = ask_tenant
    q, history, document_ids = parse_ask(raw)
    content_type "text/event-stream"
    headers "Cache-Control" => "no-cache", "X-Accel-Buffering" => "no"
    stream do |out|
      send_event = ->(name, data) { out << "event: #{name}\ndata: #{JSON.generate(data)}\n\n" }
      begin
        answer = settings.ask.call(q, history, tenant_id: tenant, document_ids: document_ids, source: "web") { |d| send_event.call("delta", { text: d }) }
        done = {
          found: answer.found, text: answer.found ? answer.text : "",
          sources: answer.sources.map do |s|
            { n: s.n, filename: s.filename, page: s.page, quote: s.quote, docx: s.filename.downcase.end_with?(".docx"),
              chunk_id: s.chunk_id, document_id: s.document_id, title: s.title, version: s.version }
          end,
          chunks: (answer.hits || []).map { |hit| WebApi.chunk(hit) }
        }
        done[:standalone] = answer.standalone if answer.standalone && Rag::Text.squash(answer.standalone) != Rag::Text.squash(q)
        send_event.call("done", done)
      rescue StandardError => e
        unless Web.client_gone?(e)
          warn "ask failed: #{e.class}"
          begin
            send_event.call("error", { message: FRIENDLY_ERROR })
          rescue StandardError => e2
            raise unless Web.client_gone?(e2)
          end
        end
      end
    end
  end

  get "/documents" do
    list_page(nil, tenant_param(params[:tenant] || Rag::DEFAULT_TENANT))
  end

  post "/documents" do
    tenant = Rag::TENANTS.include?(params[:tenant_id]) ? params[:tenant_id] : Rag::DEFAULT_TENANT
    file = params[:file]
    halt 400, list_page("Chọn một file để tải lên.", tenant) unless file.is_a?(Hash) && file[:tempfile].respond_to?(:read)
    begin
      accept_upload(params[:tenant_id], params, file)
    rescue Rag::Meta::Invalid, Rag::Upload::Rejected => e
      halt 422, list_page(e.message, tenant)
    rescue StandardError => e
      warn "upload failed: #{e.class}"
      halt 500, list_page("Không tải được file lên. Vui lòng thử lại.", tenant)
    end
    redirect "/documents?tenant=#{tenant}", 303
  end

  post "/documents/:id/delete" do
    tenant = tenant_param(params[:tenant_id])
    halt 404, "Không tìm thấy tài liệu." unless delete_document!(doc_id, tenant)
    redirect "/documents?tenant=#{tenant}", 303
  end

  get "/documents/:id" do
    doc = settings.store.document(doc_id)
    halt 404, "Không tìm thấy tài liệu." unless doc
    @doc = doc
    @name = doc.filename
    @pages = settings.store.pages(doc.id)
    n = Integer(params[:page].to_s, exception: false)
    @current = n if n && @pages.any? { |p| p.number == n }
    @quote = params[:q].to_s.strip
    @quote = nil if @quote.empty? || !@current
    erb :document
  end

  # Shared with the API (Task 7). Raises Rag::Meta::Invalid / Rag::Upload::Rejected; nothing is kept on failure.
  def accept_upload(tenant_id, fields, file)
    meta = Rag::Meta.parse(tenant_id: tenant_id, title: fields[:title], version: fields[:version],
                           valid_from: fields[:valid_from], valid_to: fields[:valid_to])
    dir = File.join(settings.documents_dir, "uploads", meta.tenant_id)
    FileUtils.mkdir_p(dir)
    path = Rag::Upload.save(filename: file[:filename], io: file[:tempfile], dir: dir, max_bytes: settings.max_upload_bytes, unique: true)
    old = settings.store.find_document(tenant_id: meta.tenant_id, title: meta.title, version: meta.version)
    begin
      prep = settings.ingest.prepare(path, meta, filename: Rag::Upload.sanitize(file[:filename]))
    rescue StandardError
      Rag::Upload.remove(path, root: uploads_root)
      raise
    end
    if prep.skipped
      Rag::Upload.remove(path, root: uploads_root)
    else
      # start_document replaced the old row; its uploaded file would be orphaned.
      Rag::Upload.remove(old.path, root: uploads_root) if old && old.path != path
      settings.worker.enqueue(prep.id, path)
    end
    prep
  end

  # Only files this app saved are removed, never data/raw samples or anything outside uploads/.
  def delete_document!(id, tenant_id)
    doc = settings.store.delete_document(id, tenant_id: tenant_id)
    return false unless doc

    Rag::Upload.remove(doc.path, root: uploads_root)
    true
  end

  private

  def uploads_root = File.join(settings.documents_dir, "uploads")

  def tenant_param(v)
    halt 400, BAD_REQUEST unless v.is_a?(String) && Rag::TENANTS.include?(v)
    v
  end

  # Document ids are small positive integers; anything else (names, huge numbers, bad bytes) is simply not found.
  def doc_id
    raw = params[:id].to_s.b
    halt 404, "Không tìm thấy tài liệu." unless raw.match?(/\A\d{1,9}\z/n)
    raw.to_i
  end

  # Absent -> default tenant; present but unknown/blank/repeated -> 400.
  def ask_tenant
    return Rag::DEFAULT_TENANT unless request.env.key?("HTTP_X_TENANT_ID")
    t = request.env["HTTP_X_TENANT_ID"]
    halt 400, "Tenant không hợp lệ." unless Rag::TENANTS.include?(t)
    t
  end

  # -> [question, history, document_ids] with history as at most 3 {q:, a:} Symbol-key hashes, or halts 400.
  def parse_ask(raw)
    data = begin
      JSON.parse(raw)
    rescue JSON::ParserError
      halt 400, BAD_REQUEST
    end
    halt 400, BAD_REQUEST unless data.is_a?(Hash)
    q, history = data["q"], data.fetch("history", [])
    halt 400, BAD_REQUEST unless q.is_a?(String) && q.valid_encoding? && !q.strip.empty?
    halt 400, BAD_REQUEST unless history.is_a?(Array) &&
                                 history.all? { |t| t.is_a?(Hash) && [t["q"], t["a"]].all? { |v| v.is_a?(String) && v.valid_encoding? } }
    ids = data.fetch("document_ids", [])
    halt 400, BAD_REQUEST unless ids.is_a?(Array) && ids.size <= MAX_DOCUMENT_IDS && ids.all? { |i| i.is_a?(Integer) && i.between?(1, WebApi::MAX_ID) }
    [q, history.last(HISTORY_TURNS).map { |t| { q: t["q"][0, HISTORY_Q_MAX], a: t["a"][0, HISTORY_A_MAX] } }, ids]
  end

  def list_page(message, tenant)
    pending = settings.worker.pending
    @tenant = tenant
    @message = message
    @rows = settings.store.documents(tenant_id: tenant).map do |d|
      waiting = pending.include?(d.id)
      label = case d.status
              when "done" then waiting ? "đang chờ" : "xong"
              when "expired" then "hết hiệu lực"
              when "error" then waiting ? "đang chờ" : "lỗi: #{d.error}"
              else waiting ? "đang xử lý" : "lỗi: bị gián đoạn, hãy tải lại file hoặc chạy lại lệnh nạp"
              end
      [d, label]
    end
    @refresh = message.nil? && @rows.any? { |d, _| pending.include?(d.id) }
    erb :documents
  end
end
