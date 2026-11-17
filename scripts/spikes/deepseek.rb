require "net/http"
require "json"
require "uri"

key = ENV["DEEPSEEK_API_KEY"].to_s
base = ENV["DEEPSEEK_API_BASE"].to_s
model = ENV["DEEPSEEK_MODEL"] || "deepseek-flash"
if key.empty? || base.empty?
  puts "STOP: .env missing or incomplete"
  exit 2
end

def check(label, ok)
  puts "#{label}: #{ok ? 'PASS' : 'FAIL'}"
  $fail = true unless ok
end

uri = URI("#{base}/chat/completions")
post = lambda do |body, &blk|
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{key}")
  req.body = body.to_json
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 120) do |http|
    blk ? http.request(req) { |r| blk.call(r) } : http.request(req)
  end
end

msg = [{ role: "user", content: "Chào bạn, hãy trả lời ngắn: 2+2 bằng mấy?" }]
res = post.({ model: model, messages: msg, reasoning: { enabled: false } })
data = (JSON.parse(res.body) rescue {})
msg0 = data.dig("choices", 0, "message") || {}
ok = res.code == "200" && !msg0["content"].to_s.empty?
check "[1a] POST /chat/completions HTTP #{res.code}, model=#{data['model'] || model}, content non-empty", ok
puts res.body[0, 300] unless ok
check "[1b] reasoning disabled honoured (no reasoning_content)", ok && !msg0.key?("reasoning_content")

events = 0
times = []
code = nil
post.({ model: model, stream: true, reasoning: { enabled: false },
        messages: [{ role: "user", content: "Viết khoảng 150 từ về lợi ích của việc nghỉ phép năm." }] }) do |r|
  code = r.code
  buf = +""
  r.read_body do |chunk|
    buf << chunk
    while (i = buf.index("\n"))
      line = buf.slice!(0..i).strip
      next unless line.start_with?("data:") && line != "data: [DONE]"
      events += 1
      times << Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
t = times.empty? ? 0 : (times.last - times.first).round(2)
check "[1c] streaming #{events} events over #{t} s (HTTP #{code})", code == "200" && events >= 5 && t >= 0.3
exit($fail ? 1 : 0)
