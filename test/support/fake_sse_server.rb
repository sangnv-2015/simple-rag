require "socket"
require "json"

# In-process HTTP server: handler.call(request) -> [status, [chunks]].
# Each chunk is a separate flushed TCP write; the body ends by closing the connection.
module FakeSSEServer
  Request = Struct.new(:path, :headers, :json_body, keyword_init: true)

  def self.start(handler)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) { |c| serve(c, handler) }
      rescue IOError, Errno::EBADF
        break
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}/v1"
  ensure
    server&.close
    thread&.join(1)
  end

  def self.serve(client, handler)
    client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    request_line = client.gets
    headers = {}
    while (line = client.gets) && line != "\r\n"
      k, v = line.chomp.split(": ", 2)
      headers[k.downcase] = v
    end
    body = client.read(headers["content-length"].to_i)
    request = Request.new(path: request_line.split[1], headers: headers,
                          json_body: body.to_s.empty? ? nil : JSON.parse(body))
    status, chunks = handler.call(request)
    client.write("HTTP/1.1 #{status} X\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
    chunks.each do |chunk|
      client.write(chunk)
      client.flush
      sleep 0.01
    end
  rescue Errno::EPIPE, Errno::ECONNRESET
    nil
  ensure
    client.close
  end
end
