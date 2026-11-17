require "informers"
require "etc"

def check(label, ok)
  puts "#{label}: #{ok ? 'PASS' : 'FAIL'}"
  $fail = true unless ok
end

puts "arch=#{RbConfig::CONFIG['host_cpu']}"
model = Informers.pipeline("embedding", "Xenova/multilingual-e5-small", dtype: "q8")
q, rel, unrel = model.(["query: Nghỉ phép năm được bao nhiêu ngày?",
                        "passage: Nhân viên được nghỉ phép năm 12 ngày mỗi năm.",
                        "passage: Công thức nấu phở bò cần xương ống và quế hồi."])
check "[2] q8 model loaded, dim=#{q.size}", q.size == 384
norm = Math.sqrt(q.sum { |x| x * x })
check "[2] vector L2 norm within 1.0 +/- 0.01", (norm - 1).abs <= 0.01
dot = ->(a, b) { a.zip(b).sum { |x, y| x * y } }
check "[6-pre] cos(query, relevant passage) > cos(query, unrelated passage)", dot.(q, rel) > dot.(q, unrel)

# varied dense prose (numbers, proper nouns, no repetition), cut to 1000 chars
text = <<~T.gsub(/\s+/, " ").strip[0, 1000]
  Theo Quyết định số 245/QĐ-TCT ngày 12 tháng 3 năm 2024 của Tổng giám đốc Nguyễn Văn Hoàng, nhân viên chính thức được nghỉ phép năm 12 ngày làm việc, cộng thêm 1 ngày cho mỗi 5 năm thâm niên. Công ty Cổ phần Công nghệ Thăng Long có trụ sở tại số 18 phố Duy Tân, quận Cầu Giấy, Hà Nội, và chi nhánh tại thành phố Hồ Chí Minh, đường Nguyễn Thị Minh Khai. Khoản phụ cấp ăn trưa là 730.000 đồng mỗi tháng, phụ cấp xăng xe 500.000 đồng, còn thưởng hiệu suất quý được tính từ 0,5 đến 2,0 lần lương cơ bản tùy xếp loại A, B hoặc C. Trường hợp làm thêm giờ vào ngày lễ, mức chi trả bằng 300% tiền lương giờ, theo Điều 98 Bộ luật Lao động 2019. Phòng Nhân sự do bà Trần Thị Mai Phương phụ trách sẽ tiếp nhận đơn xin nghỉ trước ít nhất 3 ngày, đồng thời thông báo cho trưởng bộ phận qua email nội bộ. Nhân viên thử việc chưa được hưởng chế độ bảo hiểm y tế bổ sung của Bảo Việt, nhưng vẫn đóng BHXH theo quy định hiện hành của Nhà nước Việt Nam, mức đóng 8% lương. Mọi khiếu nại về lương thưởng được gửi đến Ban Thanh tra trong vòng 30 ngày kể từ ngày nhận phiếu lương hằng tháng.
T
abort "FAIL sample is #{text.size} chars, need 1000" unless text.size == 1000
tok = Tokenizers.from_pretrained("Xenova/multilingual-e5-small")
n = tok.encode(text).tokens.size
check "[5] 1000 Vietnamese chars = #{n} tokens", n <= 450
ok = begin
  long = text * 3
  abort "FAIL long input is #{long.size} chars" unless long.size == 3000
  v = model.("passage: " + long)
  v.size == 384
rescue => e
  puts e.message[0, 200]
  false
end
check "[5] 3000-char input embeds without error", ok
puts "MAX_CHUNK_CHARS candidate=#{n <= 450 ? 1000 : (1000 * 450 / n) / 50 * 50}"
exit($fail ? 1 : 0)
