require "net/http"
require "json"
require "uri"
require "openssl"
require "timeout"
require "zlib"

module Rag
  # Chat client for an OpenAI-compatible gateway. Error messages are fixed strings: they never carry
  # the key, host, URL or response body (only status, exception class and a truncated body go to $stderr).
  class DeepSeek
    class Error < Rag::Error; end

    NETWORK_ERRORS = [SocketError, SystemCallError, Timeout::Error, EOFError, IOError, OpenSSL::SSL::SSLError,
                      URI::InvalidURIError, Net::HTTPBadResponse, Zlib::Error].freeze

    def initialize(api_key:, base_url:, model: "deepseek-flash", read_timeout: 120)
      @api_key = api_key
      @base_url = base_url
      @model = model
      @read_timeout = read_timeout
    end

    # Default inspect/pp would print @api_key and @base_url (also via Ingest/Ask/System ivars).
    def inspect = "#<Rag::DeepSeek model=#{@model.inspect}>"
    def pretty_print(q) = q.text(inspect)

    def chat(messages, &on_delta)
      body = {model: @model, messages: messages, reasoning: {enabled: false}, temperature: 0}
      body[:stream] = true if on_delta
      started = false
      callback_error = nil
      if on_delta
        user_block = on_delta
        on_delta = lambda do |t|
          user_block.call(t)
        rescue StandardError => e
          callback_error = e
          raise
        end
      end
      begin
        uri = URI.parse(@base_url.chomp("/") + "/chat/completions")
        raise URI::InvalidURIError, "no host" unless uri.is_a?(URI::HTTP) && uri.host

        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{@api_key}"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = @read_timeout
        http.request(req) do |res|
          started = true
          return handle(res, &on_delta)
        end
      rescue *NETWORK_ERRORS => e
        raise callback_error if callback_error # the caller's own exception, not a network failure

        warn "DeepSeek request failed: #{e.class}"
        raise Error, started ? "DeepSeek ngắt kết nối giữa chừng" : "Không kết nối được DeepSeek"
      end
    end

    private

    def handle(res, &on_delta)
      unless res.is_a?(Net::HTTPSuccess)
        warn "DeepSeek HTTP #{res.code}: #{redact(res.read_body)}"
        raise Error, "Không gọi được DeepSeek (HTTP #{res.code})"
      end
      return stream(res, &on_delta) if on_delta

      raw = res.read_body
      parsed = JSON.parse(raw)
      fail_invalid(raw) if parsed.is_a?(Hash) && parsed.key?("error")
      choice = parsed.is_a?(Hash) && parsed["choices"].is_a?(Array) ? parsed["choices"][0] : nil
      message = choice.is_a?(Hash) ? choice["message"] : nil
      fail_invalid(raw) unless message.is_a?(Hash)
      message["content"].is_a?(String) ? message["content"] : ""
    rescue JSON::ParserError
      raise Error, "DeepSeek trả về dữ liệu không hợp lệ"
    end

    def fail_invalid(raw)
      warn "DeepSeek invalid response: #{redact(raw)}"
      raise Error, "DeepSeek trả về dữ liệu không hợp lệ"
    end

    # Redact before truncating so a secret cannot be cut in half and slip past.
    def redact(text)
      host = (URI.parse(@base_url).host rescue nil)
      [@api_key, @base_url, @base_url.chomp("/"), host].compact.reject(&:empty?).uniq
        .sort_by { |x| -x.size }.reduce(text.to_s.dup) { |t, secret| t.gsub(secret, "[redacted]") }[0, 300]
    end

    def stream(res, &on_delta)
      out = +""
      buffer = +""
      done = false
      res.read_body do |chunk|
        next if done

        buffer << chunk.force_encoding(Encoding::UTF_8)
        while (nl = buffer.index("\n"))
          line = buffer.slice!(0..nl).strip
          next unless line.start_with?("data:")

          data = line.delete_prefix("data:").strip
          if data == "[DONE]"
            done = true
            break
          end
          event = begin
            JSON.parse(data)
          rescue JSON::ParserError
            next
          end
          next unless event.is_a?(Hash)
          fail_invalid(data) if event.key?("error")

          choice = event["choices"].is_a?(Array) ? event["choices"][0] : nil
          delta = choice.is_a?(Hash) ? choice["delta"] : nil
          text = delta.is_a?(Hash) ? delta["content"] : nil
          next unless text.is_a?(String) && !text.empty?

          out << text
          on_delta.call(text)
        end
      end
      raise Error, "DeepSeek ngắt kết nối giữa chừng" unless done

      out
    end
  end
end
