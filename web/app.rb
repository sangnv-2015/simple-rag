require "json"
require "sinatra/base"
require_relative "../lib/rag"

class Web < Sinatra::Base
  FRIENDLY_ERROR = "Không thể trả lời lúc này. Vui lòng thử lại sau.".freeze
  # Errors from writing to a browser that went away: nothing to report.
  CLIENT_GONE = [IOError, Errno::EPIPE, Errno::ECONNRESET, (Puma::ConnectionError if defined?(Puma::ConnectionError))].compact.freeze

  set :views, File.expand_path("views", __dir__)
  set :host_authorization, permitted_hosts: ["localhost", "127.0.0.1", "[::1]"]
  set :show_exceptions, false
  set :erb, escape_html: true
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
          found: answer.found, text: answer.text,
          sources: answer.sources.map { |s| { n: s.n, filename: s.filename, page: s.page, quote: s.quote, docx: s.filename.downcase.end_with?(".docx") } }
        })
      rescue *CLIENT_GONE
        nil
      rescue StandardError => e
        warn "ask failed: #{e.class}"
        begin
          send_event.call("error", { message: FRIENDLY_ERROR })
        rescue *CLIENT_GONE
          nil
        end
      end
    end
  end
end
