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
  set :show_exceptions, false
  set :ask, nil
  set :store, nil
  set :worker, nil
  set :documents_dir, nil
  set :max_upload_bytes, Rag::MAX_UPLOAD_BYTES

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
end
