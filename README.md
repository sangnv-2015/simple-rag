# Demo hỏi đáp tài liệu (RAG) bằng Ruby

Nạp file PDF và Word (.docx), rồi hỏi bằng tiếng Việt hoặc tiếng Anh. Mỗi câu trả lời hiện dần và kèm nguồn: tên file, số trang, đoạn trích nguyên văn. Nếu tài liệu không có thông tin, app trả lời `Không tìm thấy thông tin này trong tài liệu.`

Quyền riêng tư: nội dung tài liệu được gửi tới endpoint DeepSeek khi nạp và khi trả lời. Mô hình tạo vector chạy cục bộ. Web chỉ mở trên `localhost` (không có đăng nhập).

## 1. Cài đặt (một lần)

```bash
cp .env.example .env
```

Mở `.env`, điền `DEEPSEEK_API_KEY` và `DEEPSEEK_API_BASE` (địa chỉ endpoint của công ty, không có dấu `/` ở cuối). `DEEPSEEK_MODEL` là tùy chọn, mặc định `deepseek-flash`. Không commit file `.env`.

Endpoint của công ty là một gateway (LiteLLM phía trước OpenRouter). Gateway này từ chối trường `thinking` của DeepSeek; trường tắt chế độ suy nghĩ phải là `reasoning: {enabled: false}`, và code đang gửi đúng trường này.

## 2. Chuẩn bị máy trước buổi demo

Bắt đầu từ trạng thái sạch để phần tải file lên ở cuối demo là thật. Chạy lần lượt:

```bash
docker compose down -v
docker compose up -d
docker compose run --rm app bin/ingest
```

- `docker compose down -v` xóa CHỈ dữ liệu của dự án này: volume cơ sở dữ liệu (`pgdata`, mọi tài liệu đã nạp, kể cả file đã tải lên thử) và volume cache mô hình (`models`). Mô hình tạo vector được tải lại, khoảng 118 MB. File trong `documents/` và code không bị xóa.
- Lần chạy đầu build image (khoảng 1 GB) và tải image Postgres, mất vài phút. Hãy làm trước giờ demo.
- `bin/ingest` nạp thư mục `documents/` (3 file mẫu). Kết quả mong đợi:

```
OK: quy-che-nghi-phep.pdf, quy-dinh-lam-viec-tu-xa.docx, travel-expense-policy.pdf
```

- Chạy `bin/ingest` lần nữa thì các file không đổi được bỏ qua và không tốn lệnh gọi trả phí:

```
Bỏ qua (không đổi): quy-che-nghi-phep.pdf, quy-dinh-lam-viec-tu-xa.docx, travel-expense-policy.pdf
```

Mở http://localhost:4567 để dùng.

## 3. Kịch bản demo

Câu hỏi lấy nguyên văn từ `samples/questions.yml`. Trả lời của mô hình có thể khác chữ, nhưng ý và nguồn phải như dưới đây.

1. Hỏi khác chữ với tài liệu (trang Hỏi đáp): `Ngày phép năm ngoái dùng không hết thì được giữ lại sang năm nay mấy ngày?`
   Mong đợi: chuyển tối đa 5 ngày, dùng trước ngày 31/03 năm sau. Nguồn `quy-che-nghi-phep.pdf · trang 2` kèm đoạn trích. Tài liệu viết "chưa dùng hết", câu hỏi viết khác, vẫn tìm ra: đó là tìm theo nghĩa.
2. Câu hỏi về bảng: `Tôi sắp lấy vợ thì được nghỉ có lương mấy ngày?`
   Mong đợi: 3 ngày làm việc. Nguồn `quy-che-nghi-phep.pdf · trang 3`, đoạn trích là một dòng bảng: `| Bản thân kết hôn | nghỉ 3 ngày làm việc |`.
3. Bấm vào nguồn `[1]` của câu trên. Trang Tài liệu mở ra đúng trang, hai cột: `Chữ gốc` (chữ rút từ PDF) và `Markdown (DeepSeek dựng lại)` (có tiêu đề, bảng). Đây là chỗ để người xem tự đối chiếu. Trang bị đánh dấu `Đã dùng chữ gốc vì markdown thiếu số liệu` nghĩa là bước dựng lại làm mất số và app đã giữ chữ gốc.
4. Câu hỏi không có đáp án: `Công ty thưởng Tết bao nhiêu tháng lương?`
   Mong đợi: chỉ có dòng `Không tìm thấy thông tin này trong tài liệu.`, không có nguồn.
5. Tải file lên ngay trên màn hình: mở trang `Tài liệu`, chọn `samples/upload-demo/chinh-sach-hoan-tien.docx`, bấm `Tải lên`. Trạng thái là `đang xử lý`, trang tự làm mới, đến `xong` thì hỏi: `Hàng về tay được 10 ngày rồi, giờ muốn trả thì được hoàn bao nhiêu phần trăm?`
   Mong đợi: 70%, nguồn `chinh-sach-hoan-tien.docx`. Trong lúc chờ, trang Hỏi đáp vẫn dùng được. Chờ khoảng 18 giây (số ghi nhận khi thử file mẫu này).

Lưu ý: số trang của nguồn `.docx` là số trang của bản PDF đã chuyển đổi, hiển thị `trang N (bản PDF)`.

Số liệu đã đo (xem `spikes/RESULTS.md`): truy xuất đúng 10/10 trên bộ câu hỏi mẫu với `Xenova/multilingual-e5-small`; chữ đầu tiên của câu trả lời hiện sau khoảng một đến hai giây khi tắt chế độ suy nghĩ (đo trực tiếp trên gateway: 1,53 giây so với 6,79 giây khi bật); image `app` khoảng 1 GB (1,04 GB).

## 4. Bộ câu hỏi chạy tay

`samples/questions.yml` có 10 câu hỏi có đáp án trong 3 file mẫu, 1 câu có đáp án trong file tải lên (`after_upload: true`), và 2 câu không có đáp án. Mỗi câu có `file` (file chứa đáp án) và `contains` (cụm chữ phải có trong đoạn tìm được); câu không có đáp án có `probe` (từ khóa để kiểm tra tài liệu quả thật không có).

Kiểm tra phần tìm kiếm (không gọi dịch vụ trả phí):

```bash
docker compose run --rm app bin/check_retrieval
```

Với mỗi câu có đáp án (trừ câu sau khi tải lên), lệnh in thứ hạng của đoạn đúng trong 6 đoạn đầu (hoặc `MISS`), cuối cùng `N/M in top 6`. Kết thúc bằng mã lỗi nếu dưới 80%. Kết quả hiện tại: `10/10 in top 6`.

Chất lượng câu trả lời không được đánh giá tự động: hãy hỏi tay từng câu và so với `file`, `contains`.

## 5. Phát triển

```bash
docker compose run --rm app bin/test                 # chạy toàn bộ test (không gọi DeepSeek, không tải mô hình)
docker compose run --rm app bin/ask "câu hỏi"        # dùng lõi không qua web (có gọi DeepSeek)
docker compose run --rm app bin/build_samples        # tạo lại file mẫu từ samples/src
```

`bin/build_samples` là nguồn của `documents/` và `samples/upload-demo/`: không sửa tay các file đó. Mã nguồn được mount vào container nên sửa là có hiệu lực khi chạy lại lệnh; riêng web cần `docker compose restart app`.

## 6. Xử lý sự cố

- Trình duyệt báo 403: bạn đang vào bằng tên máy khác `localhost`, `127.0.0.1`, `[::1]`. Dùng `http://localhost:4567`.
- Thiếu biến môi trường: điền `DEEPSEEK_API_KEY` và `DEEPSEEK_API_BASE` trong `.env`.
- File PDF scan: không có OCR, trang không có lớp chữ được báo là không đọc được; file chỉ toàn trang như vậy báo lỗi `file scan, không đọc được`.
- File ở trạng thái `lỗi: bị gián đoạn, hãy tải lại file hoặc chạy lại lệnh nạp` (do khởi động lại giữa lúc xử lý): chạy lại `docker compose run --rm app bin/ingest`, hoặc tải file lên lại.
- Muốn xóa sạch dữ liệu và cache mô hình: `docker compose down -v`, sau đó `up -d` và `bin/ingest` lại.
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

- `Rag::Report` có bốn thành phần: `ok`, `skipped`, `failed` (mảng `[tên file, thông báo]`), `empty_dir`; cùng `failed?` và `summary`. `Ingest` không ném lỗi theo từng file mà ghi vào `failed`.
- `Rag::Answer` có `text`, `found`, `sources`; mỗi `Rag::Source` có `n`, `filename`, `page`, `quote` (`nil` nếu không xác minh được). Khi `found` là false thì không có nguồn.
- Phần trả lời được stream qua block; phần trích dẫn do mô hình in sau dấu `Rag::Ask::TOKEN` (`<<QUOTES>>`) bị lọc ra khỏi stream và được kiểm tra bằng code.

Ba thành phần cần có các phương thức sau (tên đúng như trong code):

- `llm`: `chat(messages, &on_delta)`. `messages` là mảng `{role:, content:}`. Có block thì stream, gọi block với từng đoạn chữ rồi trả về toàn bộ chữ; không có block thì trả chuỗi. Lỗi nên là lớp con của `Rag::Error` (message của nó được hiển thị).
- `embedder`: `embed_passages(texts)` trả mảng vector (cho đoạn tài liệu), `embed_query(text)` trả một vector (cho câu hỏi). Kích thước vector là `Rag::EMBED_DIM` (384).
- `store`: `find_document(filename)`, `start_document(filename:, sha256:)` (trả id), `finish_document(id, pages:, chunks:)`, `fail_document(id, message)`, `search(embedding, k)` (trả mảng `Rag::Hit`). Web demo còn dùng `documents` và `pages(filename)`. Kiểu dữ liệu: `Rag::Page`, `Rag::Chunk`, `Rag::Doc`, `Rag::Hit` trong `lib/rag.rb`.

Thay thế:

- Thay `Rag::Store` (Postgres và pgvector) bằng lớp lưu trữ của hệ thống thật, cài đủ các phương thức trên.
- Thay `Rag::DeepSeek` bằng client LLM của hệ thống. Nếu hệ thống gọi thẳng DeepSeek (không qua gateway công ty), phải đổi trường trong `lib/rag/deepseek.rb` từ `reasoning: {enabled: false}` về `thinking: {type: "disabled"}`.
- Giữ nguyên bước kiểm tra đoạn trích và kiểm tra con số: đó là thứ làm cho câu trả lời đáng tin.

Phụ thuộc: gem `informers` (mô hình `Xenova/multilingual-e5-small`), `pg`, `pgvector` (chỉ khi dùng `Rag::Store`); gói hệ thống `poppler-utils` (rút chữ PDF), và LibreOffice Writer (`libreoffice-writer-nogui`, chỉ để đổi `.docx` sang PDF). Xem `Dockerfile` và `Gemfile`.

Demo bỏ qua: đăng nhập và phân quyền, mở rộng tải, OCR, và nhớ hội thoại.
