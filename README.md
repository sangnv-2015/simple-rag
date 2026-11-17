# Demo hỏi đáp tài liệu (RAG) bằng Ruby

Nạp file PDF và Word (.docx), rồi hỏi bằng tiếng Việt hoặc tiếng Anh. Mỗi câu trả lời hiện dần và kèm nguồn: tên file, số trang, đoạn trích. Đoạn trích được kiểm tra khớp từng chữ với đoạn đã nạp (với bảng và trang được DeepSeek dựng lại, đoạn đã nạp là markdown dựng lại, nên trích từ bảng có dấu `|`). Nếu tài liệu không có thông tin, app trả lời `Không tìm thấy thông tin này trong tài liệu.`

Quyền riêng tư: nội dung tài liệu được gửi tới endpoint DeepSeek khi nạp và khi trả lời. Mô hình tạo vector chạy cục bộ. Web chỉ mở trên `localhost` (không có đăng nhập).

## 1. Cài đặt (một lần)

Cần Docker với Compose v2.24 trở lên. Mọi lệnh chạy từ thư mục gốc của repo.

```bash
cp .env.example .env
```

Mở `.env`, điền `DEEPSEEK_API_KEY` và `DEEPSEEK_API_BASE` (địa chỉ endpoint của công ty, không có dấu `/` ở cuối). `DEEPSEEK_MODEL` là tùy chọn, mặc định `deepseek-flash`. Không commit file `.env`.

Endpoint của công ty là một gateway (LiteLLM phía trước OpenRouter). Gateway này từ chối trường `thinking` của DeepSeek; trường tắt chế độ suy nghĩ phải là `reasoning: {enabled: false}`, và code đang gửi đúng trường này.

## 2. Chuẩn bị máy trước buổi demo

Bắt đầu từ trạng thái sạch để phần tải file lên ở cuối demo là thật. Chạy lần lượt:

```bash
docker compose down -v
rm -f documents/chinh-sach-hoan-tien.docx
ls documents
docker compose run --rm app bin/ingest
docker compose up -d
```

- `docker compose down -v` xóa CHỈ dữ liệu của dự án này: volume cơ sở dữ liệu (`pgdata`, mọi dòng tài liệu đã nạp) và volume cache mô hình (`models`). Mô hình tạo vector được tải lại, khoảng 118 MB. Code không bị xóa.
- File đã tải lên khi tập thử KHÔNG nằm trong volume mà nằm trong thư mục `documents/` trên máy, nên `down -v` không xóa chúng. Vì vậy phải có dòng `rm -f documents/chinh-sach-hoan-tien.docx`, và `ls documents` phải hiện đúng 3 file: `quy-che-nghi-phep.pdf`, `quy-dinh-lam-viec-tu-xa.docx`, `travel-expense-policy.pdf`. Nếu có file khác (ví dụ file tải lên thử khác), xóa nó đi, vì `bin/ingest` nạp cả thư mục và sẽ tốn thêm lệnh gọi trả phí.
- Chạy `bin/ingest` TRƯỚC `up -d`: lệnh này tự khởi động cơ sở dữ liệu, tải mô hình một lần rồi nạp. Làm ngược lại thì hai container có thể cùng tải mô hình vào một cache.
- Lần nạp đầu gọi DeepSeek một lần cho mỗi trang (12 trang cho 3 file mẫu); thời gian chạy chưa được đo.
- Lần chạy đầu cũng build image (khoảng 1 GB) và tải image Postgres, mất vài phút. Hãy làm trước giờ demo.
- Kết quả mong đợi của `bin/ingest`:

```
OK: quy-che-nghi-phep.pdf, quy-dinh-lam-viec-tu-xa.docx, travel-expense-policy.pdf
```

- Chạy `bin/ingest` lần nữa thì các file không đổi được bỏ qua và không tốn lệnh gọi trả phí:

```
Bỏ qua (không đổi): quy-che-nghi-phep.pdf, quy-dinh-lam-viec-tu-xa.docx, travel-expense-policy.pdf
```

Sau `up -d`, chờ vài giây cho đến khi `docker compose logs app` hiện dòng `* Listening on http://0.0.0.0:4567` (Puma đang lắng nghe), rồi mới mở http://localhost:4567.

Sau buổi demo, dọn file đã tải lên bằng `rm -f documents/chinh-sach-hoan-tien.docx` (và `docker compose down -v` nếu muốn xóa cả dữ liệu).

## 3. Kịch bản demo

Câu hỏi lấy nguyên văn từ `samples/questions.yml`. Trả lời của mô hình có thể khác chữ, nhưng ý và nguồn phải như dưới đây.

1. Hỏi khác chữ với tài liệu (trang Hỏi đáp): `Ngày phép năm ngoái dùng không hết thì được giữ lại sang năm nay mấy ngày?`
   Mong đợi: chuyển tối đa 5 ngày, dùng trước ngày 31/03 năm sau. Nguồn `quy-che-nghi-phep.pdf · trang 2` kèm đoạn trích. Tài liệu viết "chưa dùng hết", câu hỏi viết khác, vẫn tìm ra: đó là tìm theo nghĩa.
2. Câu hỏi về bảng: `Tôi sắp lấy vợ thì được nghỉ có lương mấy ngày?`
   Mong đợi: 3 ngày làm việc. Nguồn `quy-che-nghi-phep.pdf · trang 3`, đoạn trích là một dòng bảng: `| Bản thân kết hôn | nghỉ 3 ngày làm việc |`.
3. Bấm vào nguồn `[1]` của câu trên. Trang Tài liệu mở ra đúng trang, hai cột: `Chữ gốc` (chữ rút từ PDF) và `Markdown (DeepSeek dựng lại)` (có tiêu đề, bảng). Đây là chỗ để người xem tự đối chiếu. Trang bị đánh dấu `Đã dùng chữ gốc vì markdown thiếu số liệu` nghĩa là bước dựng lại làm mất số và app đã giữ chữ gốc.
4. Câu hỏi không có đáp án: `Công ty thưởng Tết bao nhiêu tháng lương?`
   Mong đợi: chỉ có dòng `Không tìm thấy thông tin này trong tài liệu.`, không có nguồn.
5. Tải file lên ngay trên màn hình: mở trang `Tài liệu`, chọn `samples/upload-demo/chinh-sach-hoan-tien.docx`, bấm `Tải lên`. Trạng thái đầu có thể là `đang chờ`, rồi `đang xử lý`, rồi `xong`. Trong lúc chờ có thể sang trang Hỏi đáp thử; quay lại trang Tài liệu để thấy `xong`, rồi hỏi: `Hàng về tay được 10 ngày rồi, giờ muốn trả thì được hoàn bao nhiêu phần trăm?`
   Mong đợi: 70%, nguồn `chinh-sach-hoan-tien.docx`. Trong lúc chờ, trang Hỏi đáp vẫn dùng được. Chờ khoảng 18 giây (số ghi nhận khi thử file mẫu này).

Lưu ý: số trang của nguồn `.docx` là số trang của bản PDF đã chuyển đổi, hiển thị `trang N (bản PDF)`.

Số liệu đã đo (xem `spikes/RESULTS.md`): truy xuất đúng 10/10 trên bộ câu hỏi mẫu với `Xenova/multilingual-e5-small`; trong lần thử trực tiếp, gateway trả chữ đầu tiên sau 1,53 giây khi tắt chế độ suy nghĩ (6,79 giây khi để bật); từ dòng lệnh, `bin/ask` hiện chữ đầu tiên sau khoảng 3 giây, tính cả khoảng 2 giây khởi động container; trên web, câu trả lời hiện dần; image `app` khoảng 1 GB (1,04 GB).

## 4. Bộ câu hỏi chạy tay

`samples/questions.yml` có 10 câu hỏi có đáp án trong 3 file mẫu, 1 câu có đáp án trong file tải lên (`after_upload: true`), và 2 câu không có đáp án. Mỗi câu có `file` (file chứa đáp án) và `contains` (cụm chữ phải có trong đoạn tìm được); câu không có đáp án có `probe` (từ khóa để kiểm tra tài liệu đúng là không có).

Kiểm tra phần tìm kiếm (không gọi dịch vụ trả phí):

```bash
docker compose run --rm app bin/check_retrieval
```

Với mỗi câu có đáp án (trừ câu sau khi tải lên), lệnh in thứ hạng của đoạn đúng trong 6 đoạn đầu (hoặc `MISS`), cuối cùng `N/M in top 6`. Lệnh thoát với mã lỗi 1 nếu dưới 80%. Kết quả hiện tại: `10/10 in top 6`.

Chất lượng câu trả lời không được đánh giá tự động: hãy hỏi tay từng câu và so với `file`, `contains`.

## 5. Phát triển

```bash
docker compose run --rm app bin/test                 # chạy toàn bộ test (không gọi DeepSeek, không tải mô hình)
docker compose run --rm app bin/ask "câu hỏi"        # dùng lõi không qua web (có gọi DeepSeek)
docker compose run --rm app bin/build_samples        # tạo lại file mẫu từ samples/src
```

`bin/build_samples` là nguồn của `documents/` và `samples/upload-demo/`: không sửa tay các file đó. Mã nguồn được mount vào container nên sửa là có hiệu lực khi chạy lại lệnh; riêng web cần `docker compose restart app`.

## 6. Xử lý sự cố

- Trình duyệt báo 403: bạn đang vào bằng tên máy không phải `localhost`, `127.0.0.1` hay `[::1]`. Dùng `http://localhost:4567`.
- Thiếu file `.env` hoặc thiếu biến trong file đó: container web thoát ngay khi khởi động, thông báo tiếng Việt nằm trong `docker compose logs app`. Điền `DEEPSEEK_API_KEY` và `DEEPSEEK_API_BASE`.
- Sai key hoặc endpoint: trang chỉ hiện `Không thể trả lời lúc này. Vui lòng thử lại sau.`; lý do nằm trong `docker compose logs app`.
- Sau khi sửa `.env`, chạy `docker compose up -d --force-recreate app` để container nhận giá trị mới.
- File PDF scan: không có OCR, trang không có lớp chữ được báo là không đọc được; file chỉ toàn trang như vậy báo lỗi `file scan, không đọc được`.
- File ở trạng thái `lỗi: bị gián đoạn, hãy tải lại file hoặc chạy lại lệnh nạp` (do khởi động lại giữa lúc xử lý): chạy lại `docker compose run --rm app bin/ingest`, hoặc tải file lên lại.
- Muốn xóa sạch dữ liệu và cache mô hình: làm lại các lệnh ở mục 2 (`down -v`, xóa file tải lên khỏi `documents/`, `bin/ingest`, `up -d`). `down -v` không xóa file đã tải lên trong `documents/`.
- Đổi mô hình tạo vector (`EMBED_MODEL` trong `lib/rag.rb`) cần `docker compose down -v` rồi nạp lại.
- Dừng app sau demo: `docker compose stop`.

## 7. Giới hạn đã biết

- Không có đăng nhập; chỉ chạy trên `localhost`.
- Không OCR: trang scan được báo là không đọc được.
- Mỗi câu hỏi độc lập, không nhớ câu hỏi trước.
- Nội dung tài liệu được gửi tới endpoint mô hình khi nạp và khi trả lời.
- Kiểm tra số sau khi dựng lại bắt được số bị đổi hoặc bị mất, nhưng không bắt được hai số bị hoán đổi cho nhau, và không kiểm tra được trang không có số. Cách kiểm tra là xem trang hai cột.
- Đoạn trích hiển thị đã được kiểm tra khớp từng chữ với đoạn được dẫn. Nguồn nào không xác minh được đoạn trích thì hiển thị `không xác minh được đoạn trích`.
- File không phải Word nhưng đổi đuôi thành `.docx` và bắt đầu bằng chữ ký zip có thể bị nạp thành chữ rác.
- Tải lên tối đa 30 MB, chỉ `.pdf` và `.docx`.
- Tài liệu đang xử lý mà app khởi động lại sẽ hiện là bị gián đoạn: phải tải lên lại hoặc nạp lại.
- Đổi mô hình tạo vector phải xóa dữ liệu và nạp lại.

## 8. Đưa lõi vào hệ thống thật

Lõi là `lib/rag.rb` và `lib/rag/*.rb`. Chưa đóng gói thành gem: hãy copy các file này vào dự án Ruby/Rails (`lib/rag.rb` tự `require` mọi file trong `lib/rag/`). `web/`, `bin/` và `config.ru` chỉ là phần demo.

Hai điểm vào, mỗi điểm nhận ba thành phần truyền từ ngoài:

```ruby
report = Rag::Ingest.new(llm:, embedder:, store:).call(path)   # path là file hoặc thư mục
answer = Rag::Ask.new(llm:, embedder:, store:).call(question) { |delta| ... }  # block là tùy chọn
```

- `Rag::Report` có bốn thành phần: `ok`, `skipped`, `failed` (mảng `[tên file, thông báo]`), `empty_dir`; cùng `failed?` và `summary`. `Ingest` không báo lỗi bằng exception theo từng file mà ghi vào `failed`.
- `Rag::Answer` có `text`, `found`, `sources`; mỗi `Rag::Source` có `n`, `filename`, `page`, `quote` (`nil` nếu không xác minh được). Khi `found` là false thì không có nguồn.
- Phần trả lời được stream qua block; phần trích dẫn do mô hình in sau dấu `Rag::Ask::TOKEN` (`<<QUOTES>>`) bị lọc ra khỏi stream và được kiểm tra bằng code.

Ba thành phần cần có các phương thức sau (tên đúng như trong code):

- `llm`: `chat(messages, &on_delta)`. `messages` là mảng `{role:, content:}`. Có block thì stream, gọi block với từng đoạn chữ rồi trả về toàn bộ chữ; không có block thì trả chuỗi. Lỗi nên là lớp con của `Rag::Error`: message của nó được `bin/ask` in ra và được ghi làm lý do trạng thái khi nạp. Trang hỏi đáp trên web luôn chỉ hiện thông báo cố định `Không thể trả lời lúc này. Vui lòng thử lại sau.`
- `embedder`: `embed_passages(texts)` trả mảng vector (cho đoạn tài liệu), `embed_query(text)` trả một vector (cho câu hỏi). Kích thước vector là `Rag::EMBED_DIM` (384).
- `store`: `find_document(filename)`, `start_document(filename:, sha256:)` (trả id), `finish_document(id, pages:, chunks:)`, `fail_document(id, message)`, `search(embedding, k)` (trả mảng `Rag::Hit`). Web demo còn dùng `documents` và `pages(filename)`. Hợp đồng mà lõi dựa vào: `search` chỉ trả đoạn của tài liệu có trạng thái `"done"`; các trạng thái là `"processing"`, `"done"`, `"error"`; nạp chỉ bỏ qua file khi sha256 trùng VÀ trạng thái là `"done"`; `start_document` thay thế mọi bản ghi cũ của cùng tên file, cùng với trang và đoạn của nó; `finish_document` ghi trang, đoạn và trạng thái `"done"` trong một giao dịch nguyên tử. Kiểu dữ liệu: `Rag::Page`, `Rag::Chunk`, `Rag::Doc`, `Rag::Hit` trong `lib/rag.rb`.

Thay thế:

- Thay `Rag::Store` (Postgres và pgvector) bằng lớp lưu trữ của hệ thống thật, cài đủ các phương thức trên.
- Thay `Rag::DeepSeek` bằng client LLM của hệ thống. Nếu hệ thống gọi thẳng DeepSeek (không qua gateway công ty), phải đổi trường trong `lib/rag/deepseek.rb` từ `reasoning: {enabled: false}` về `thinking: {type: "disabled"}`; đặt `DEEPSEEK_MODEL` thành mã mô hình DeepSeek thật (`deepseek-flash` ở đây là tên gọi riêng của gateway); và kiểm tra địa chỉ gốc có cần tiền tố đường dẫn không, vì code chỉ nối thêm `/chat/completions`.
- Giữ nguyên bước kiểm tra đoạn trích và kiểm tra con số: đó là thứ làm cho câu trả lời đáng tin.

Phụ thuộc: gem `informers` (mô hình `Xenova/multilingual-e5-small`), `pg`, `pgvector` (chỉ khi dùng `Rag::Store`); gói hệ thống `poppler-utils` (rút chữ PDF), LibreOffice Writer (`libreoffice-writer-nogui`) cùng font `fonts-noto-core` và `fonts-liberation2` (để dấu tiếng Việt đúng khi đổi `.docx` sang PDF; chỉ cần cho `.docx`); và Ruby 3.4. Xem `Dockerfile` và `Gemfile`.

Demo bỏ qua: đăng nhập và phân quyền, mở rộng tải, OCR, và nhớ hội thoại.
