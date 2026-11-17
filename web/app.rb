require "json"
require "sinatra/base"
require_relative "../lib/rag"

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

  set :views, File.expand_path("views", __dir__)
  set :host_authorization, permitted_hosts: ["localhost", "127.0.0.1", "[::1]"]
  use Rack::TempfileReaper
  set :show_exceptions, false
  set :ask, nil
  set :store, nil
  set :worker, nil
  set :documents_dir, nil
  set :max_upload_bytes, Rag::MAX_UPLOAD_BYTES

  TOO_LARGE = "File quá lớn (tối đa 30 MB).".freeze
  MULTIPART_OVERHEAD = 1024 * 1024
  LOCAL_ORIGIN_HOSTS = ["localhost", "127.0.0.1", "[::1]"].freeze

  # Runs before Rack parses (and spools) the body, so a huge or cross-site upload is refused unread.
  # Path-independent on purpose: Mustermann also matches percent-encoded paths (/%64ocuments).
  def call!(env)
    origin = env["HTTP_ORIGIN"]
    # Every method: a cross-site GET /ask would spend paid model calls. Plain navigations send no Origin.
    if origin && !local_origin?(origin)
      return [403, { "content-type" => "text/plain; charset=utf-8" }, ["Yêu cầu không hợp lệ."]]
    end
    if env["CONTENT_LENGTH"].to_i > settings.max_upload_bytes + MULTIPART_OVERHEAD
      return [413, { "content-type" => "text/plain; charset=utf-8" }, [TOO_LARGE]]
    end
    super
  end

  def local_origin?(origin)
    LOCAL_ORIGIN_HOSTS.include?(URI.parse(origin).host)
  rescue URI::InvalidURIError
    false
  end

  get "/" do
    @empty = settings.store.documents.none? { |d| d.status == "done" }
    erb :ask
  end

  get "/ask" do
    q = params[:q].to_s
    halt 400, "Thiếu câu hỏi." if q.strip.empty?
    content_type "text/event-stream"
    headers "Cache-Control" => "no-cache", "X-Accel-Buffering" => "no"
    stream do |out|
      send_event = ->(name, data) { out << "event: #{name}\ndata: #{JSON.generate(data)}\n\n" }
      begin
        answer = settings.ask.call(q) { |d| send_event.call("delta", { text: d }) }
        send_event.call("done", {
          found: answer.found, text: answer.found ? answer.text : "",
          sources: answer.sources.map { |s| { n: s.n, filename: s.filename, page: s.page, quote: s.quote, docx: s.filename.downcase.end_with?(".docx") } }
        })
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
    list_page
  end

  post "/documents" do
    file = params[:file]
    halt 400, list_page("Chọn một file để tải lên.") unless file.is_a?(Hash) && file[:tempfile].respond_to?(:read)
    begin
      path = Rag::Upload.save(filename: file[:filename], io: file[:tempfile],
                              dir: settings.documents_dir, max_bytes: settings.max_upload_bytes)
    rescue Rag::Upload::Rejected => e
      halt 422, list_page(e.message)
    rescue StandardError => e
      warn "upload failed: #{e.class}"
      halt 500, list_page("Không tải được file lên. Vui lòng thử lại.")
    end
    settings.worker.enqueue(path)
    redirect "/documents", 303
  end

  get "/documents/*" do
    name = params[:splat].first.to_s.dup.force_encoding(Encoding::UTF_8).scrub("_")
    halt 404, "Không tìm thấy tài liệu." if name.include?("\0")
    @name = Rag::Text.nfc(name)
    halt 404, "Không tìm thấy tài liệu." unless settings.store.find_document(@name)
    @pages = settings.store.pages(@name)
    n = Integer(params[:page].to_s, exception: false)
    @current = n if n && @pages.any? { |p| p.number == n }
    erb :document
  end

  private

  # Rows: stored documents plus names queued before ingest has created their record.
  def list_page(message = nil)
    pending = settings.worker.pending
    docs = settings.store.documents
    @message = message
    @rows = docs.map do |d|
      label = case d.status
              when "done" then pending.include?(d.filename) ? "đang chờ" : "xong"
              when "error" then pending.include?(d.filename) ? "đang chờ" : "lỗi: #{d.error}"
              else pending.include?(d.filename) ? "đang xử lý" : "lỗi: bị gián đoạn, hãy tải lại file hoặc chạy lại lệnh nạp"
              end
      [d.filename, d.page_count, d.chunk_count, label]
    end
    known = docs.map(&:filename)
    (pending - known).uniq.each { |n| @rows << [n, nil, nil, "đang chờ"] }
    @refresh = message.nil? && !pending.empty?
    erb :documents
  end
end
