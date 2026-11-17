require "net/http"
require "json"
require "uri"
require "openssl"

module Rag
  # Chat client for an OpenAI-compatible gateway. Error messages are fixed strings: they never carry
  # the key, host, URL or response body (only status, exception class and a truncated body go to $stderr).
  class DeepSeek
    class Error < Rag::Error; end

    NETWORK_ERRORS = [SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, EOFError, IOError,
                      OpenSSL::SSL::SSLError, URI::InvalidURIError].freeze

    def initialize(api_key:, base_url:, model: "deepseek-flash", read_timeout: 120)
      @api_key = api_key
      @base_url = base_url
      @model = model
      @read_timeout = read_timeout
    end

    def chat(messages, &on_delta)
      body = {model: @model, messages: messages, reasoning: {enabled: false}, temperature: 0}
      body[:stream] = true if on_delta
      started = false
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
        warn "DeepSeek request failed: #{e.class}"
        raise Error, started ? "DeepSeek ngắt kết nối giữa chừng" : "Không kết nối được DeepSeek"
      end
    end

    private

    def handle(res, &on_delta)
      unless res.is_a?(Net::HTTPSuccess)
        warn "DeepSeek HTTP #{res.code}: #{res.read_body.to_s[0, 300]}"
        raise Error, "Không gọi được DeepSeek (HTTP #{res.code})"
      end
      return stream(res, &on_delta) if on_delta

      JSON.parse(res.read_body).dig("choices", 0, "message", "content").to_s
    rescue JSON::ParserError
      raise Error, "DeepSeek trả về dữ liệu không hợp lệ"
    end

    def stream(res)
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
          text = begin
            JSON.parse(data).dig("choices", 0, "delta", "content")
          rescue JSON::ParserError
            nil
          end
          next if text.nil? || text.empty?

          out << text
          yield text
        end
      end
      raise Error, "DeepSeek ngắt kết nối giữa chừng" unless done

      out
    end
  end
end
