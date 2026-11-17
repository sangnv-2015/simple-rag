require "open3"
require "fileutils"
require "unicode_normalize/normalize"

def check(label, ok)
  puts "#{label}: #{ok ? 'PASS' : 'FAIL'}"
  $fail = true unless ok
end

def run(*cmd)
  out, err, st = Open3.capture3("timeout", "120", *cmd)
  abort "FAIL #{cmd.first}: #{err[0, 300]}" unless st.success?
  out
end

dir = "tmp/spikes"
FileUtils.mkdir_p(dir)
line = "Quy định: ệ ữ ặ ớ ẫ — Tiếng Việt có dấu chồng"
File.write("#{dir}/vi.html", <<~H)
  <html><head><meta charset="utf-8"></head><body>
  <p>#{line}</p>
  <table border="1"><tr><td>Nghỉ phép năm</td><td>12</td></tr></table>
  <table width="100%" border="1"><tr><td>Nghỉ phép năm</td><td>12</td></tr></table>
  </body></html>
H
lo = ["soffice", "--headless", "-env:UserInstallation=file:///tmp/lo-profile"]
run(*lo, "--infilter=HTML (StarWriter)", "--convert-to", "docx", "--outdir", dir, "#{dir}/vi.html")
run(*lo, "--convert-to", "pdf", "--outdir", dir, "#{dir}/vi.docx")
puts "[3] html -> docx -> pdf OK"

fonts = run("pdffonts", "#{dir}/vi.pdf").lines.drop(2).map { |l| l.split.first }.uniq
check "[3] pdffonts: #{fonts.join(', ')}", fonts.any? { |f| f =~ /Noto|Liberation/i }

text = run("pdftotext", "-layout", "#{dir}/vi.pdf", "-").unicode_normalize(:nfc)
check "[3/4] pdftotext round trip equals source text after NFC", text.gsub(/\s+/, " ").include?(line.unicode_normalize(:nfc))
check "[4] table row 'Nghỉ phép năm' keeps its number on the same line after whitespace", text.match?(/Nghỉ phép năm\s+12/)

puts "[4-info] full-width table row: #{text.lines.grep(/Nghỉ phép năm/).last.to_s.rstrip}"

run("pdftoppm", "-png", "-r", "80", "-f", "1", "-l", "1", "#{dir}/vi.pdf", "#{dir}/vi")
puts "[3] wrote #{Dir["#{dir}/vi-*.png"].first} (human: open it, no boxes or missing marks)"
exit($fail ? 1 : 0)
