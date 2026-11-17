# Simple RAG demo — bản thiết kế

Ngày: 2026-11-17 · Trạng thái: **chờ duyệt**

## 1. Mục đích

Một ứng dụng RAG nhỏ nhưng chạy trọn vòng, dùng để demo cho manager. Sau buổi demo,
manager phải thấy được RAG làm được gì trên tài liệu (PDF, Word) và hình dung được nó
nằm ở đâu trong hệ thống hiện có.

Người dùng cuối chỉ làm một việc: gõ câu hỏi và nhận câu trả lời. Nạp tài liệu là việc
hậu trường, nhưng giao diện vẫn có chỗ tải tài liệu lên.

Mô hình ngôn ngữ duy nhất được dùng là DeepSeek, qua API key và endpoint do công ty cung
cấp. Ý ban đầu là dùng Claude để đọc file; người dùng đã đổi sang chỉ dùng DeepSeek.

## 2. Mục tiêu, ngoài phạm vi, điều phải tránh

**Mục tiêu**

- Nạp file PDF và Word (.docx): rút chữ từng trang, rồi DeepSeek dựng lại thành văn bản
  có cấu trúc (tiêu đề, bảng).
- Hỏi đáp bằng tìm kiếm theo nghĩa; hỏi khác chữ với tài liệu vẫn tìm ra.
- Mọi câu trả lời kèm nguồn: tên file, số trang, đoạn trích nguyên văn.
- Trả lời "không tìm thấy trong tài liệu" khi tài liệu không có thông tin.
- Chạy sẵn được trước buổi demo, và tải thêm tài liệu được trên giao diện.
- Phần lõi tách khỏi giao diện, để chuyển vào hệ thống Ruby khác mà không viết lại.

**Ngoài phạm vi**

- Đăng nhập, phân quyền, nhiều người dùng.
- Triển khai lên server, mở rộng tải, giám sát.
- Đọc PDF scan (không có lớp chữ): không làm OCR. Trang như vậy được báo rõ là không đọc được.
- Hiểu nội dung hình ảnh, biểu đồ trong tài liệu.
- Nhớ ngữ cảnh hội thoại: mỗi câu hỏi độc lập, câu hỏi nối tiếp không hiểu câu trước.
- Loại file khác PDF và .docx.
- Đánh giá chất lượng tự động (chỉ có bộ câu hỏi thử chạy tay, mục 6).

**Điều phải tránh** (demo coi như thất bại dù chạy được)

- Câu trả lời bịa, hoặc không kèm nguồn kiểm chứng được.
- Nguồn trích sai trang, sai file, hoặc đoạn trích không có thật trong tài liệu.
- Bước dựng lại cấu trúc làm sai lệch nội dung (ví dụ chép sai con số) mà không ai thấy.
- Cài đặt rườm rà: cần thêm API key ngoài DeepSeek, hoặc hơn hai lệnh (một lệnh chạy,
  một lệnh nạp).
- Chờ lâu mà màn hình không có gì: câu trả lời phải hiện dần.

## 3. Ràng buộc

- Ngôn ngữ Ruby; chạy trong Docker trên laptop (macOS, cả amd64 và arm64).
- Chỉ một dịch vụ ngoài: DeepSeek. Cấu hình trong `.env` (không commit):
  `DEEPSEEK_API_KEY`, `DEEPSEEK_API_BASE`, và tên mô hình. Người dùng tự điền.
- Endpoint là của công ty, có thể khác DeepSeek gốc; chưa ai thử nó (xem mục 7).
- Mô hình tạo vector chạy cục bộ, không gọi dịch vụ ngoài.
- Tài liệu có thể là tiếng Việt hoặc tiếng Anh; câu trả lời theo ngôn ngữ của câu hỏi.
- Nội dung tài liệu được gửi tới endpoint DeepSeek khi nạp và khi trả lời.
- Web chỉ mở trên `localhost`, vì không có đăng nhập.

## 4. Các cách đã cân nhắc

**Cách tìm kiếm**

| Cách | Được | Mất |
|---|---|---|
| **A. Tìm theo nghĩa (vector)** — đã chọn | Hỏi khác chữ vẫn ra; đúng kiến trúc sẽ dùng thật | Cần thêm mô hình tạo vector |
| B. Tìm theo từ khóa | Ít thành phần nhất | Từ đồng nghĩa, diễn đạt khác là trượt |
| C. Đưa hết tài liệu cho mô hình | Đơn giản nhất, tốt khi ít file | Không phải RAG; tốn theo từng câu hỏi; không chạy khi nhiều tài liệu |

**Cách đọc file** (sau khi chỉ còn DeepSeek, vốn chỉ nhận chữ)

| Cách | Được | Mất |
|---|---|---|
| **1. Rút chữ rồi DeepSeek dựng lại cấu trúc, không OCR** — đã chọn | Bảng rõ ràng, tìm kiếm tốt hơn, thấy được AI ở bước đọc file | Có thể chép sai; phải giữ bản gốc để đối chiếu |
| 2. Chỉ rút chữ | Nhanh, rẻ, không chép sai | Bảng thô; bước đọc file không có gì để xem |
| 3. Cách 1 cộng OCR | Đọc được file scan | Image nặng, OCR tiếng Việt thất thường, thêm chỗ dễ hỏng |

Người dùng chọn **A**, **cách 1 không OCR**, viết bằng **Ruby**, chạy bằng **Docker**,
chỉ dùng **DeepSeek**.

## 5. Thiết kế

### 5.1 Các phần

```
documents/  (PDF, .docx)  ◄── lệnh nạp, hoặc tải lên qua web
    ▼
[Đổi .docx → PDF] → [Rút chữ từng trang] → [DeepSeek dựng lại → markdown từng trang]
    → [Cắt đoạn] → [Tạo vector] → [Kho lưu: tài liệu, trang (chữ gốc + markdown), đoạn, vector]
                                              ▲
câu hỏi → [Tạo vector câu hỏi] → [Lấy các đoạn gần nhất] → [DeepSeek trả lời + nguồn]
        → [Kiểm tra đoạn trích] → web
```

- **Lõi** (Ruby thuần, không phụ thuộc web): hai điểm vào là `nạp(file hoặc thư mục)` và
  `hỏi(câu hỏi) → câu trả lời hiện dần + danh sách nguồn`. Mô hình ngôn ngữ, mô hình tạo
  vector và kho lưu đều được truyền vào từ ngoài, để test thay bằng đồ giả và để hệ thống
  đích thay bằng thành phần của nó. Không đóng gói thành gem.
- **Web** (lớp mỏng): trang hỏi đáp và trang "Tài liệu".
- **Lệnh nạp**: chạy trong container, ví dụ `docker compose run --rm app bin/ingest`.

**Cách chạy demo:** người trình bày chuẩn bị máy trước buổi demo: `docker compose up`,
rồi chạy lệnh nạp một lần. Việc tải mô hình tạo vector và nạp tài liệu mẫu xảy ra ở bước
chuẩn bị này. Dữ liệu và mô hình nằm trong volume nên lần chạy sau không phải làm lại.
Không tự nạp khi khởi động. Trong buổi demo có thể tải thêm một file qua web để manager
thấy quá trình nạp.

**Số trang trong nguồn trích** là số thứ tự trang của file PDF (trang đầu là 1), không
phải số in trên trang. Với .docx, đó là trang của bản PDF đã đổi, có thể lệch so với khi
mở bằng Word; giao diện ghi rõ "trang N (bản PDF)" cho nguồn từ .docx.

### 5.2 Nạp tài liệu

1. Bỏ qua file đã nạp mà nội dung không đổi (so mã băm); file đổi nội dung thì xóa dữ
   liệu cũ của file đó rồi nạp lại.
2. File .docx được đổi sang PDF trong container, sau đó đi chung đường với PDF.
3. Rút chữ từng trang, giữ bố cục cột. Trang không có chữ (scan) được đánh dấu "không
   đọc được" và bỏ qua; file toàn trang như vậy báo lỗi "file scan, không đọc được".
4. DeepSeek nhận chữ của từng trang và trả về markdown của trang đó: giữ tiêu đề, danh
   sách, dựng bảng thành bảng markdown. Không tóm tắt, không dịch, không thêm bớt. Cả
   chữ gốc lẫn markdown đều được lưu.
5. Kiểm tra sau khi dựng lại: mọi con số có trong chữ gốc của trang phải còn trong
   markdown. Nếu thiếu, trang đó dùng chữ gốc thay cho markdown và được đánh dấu để hiện
   trên trang "Tài liệu".
6. Mỗi trang được cắt thành đoạn theo tiêu đề và đoạn văn; bảng không bị cắt đôi. Mỗi
   đoạn mang theo tên file và số trang.
7. Tạo vector cho từng đoạn và lưu.
8. Một file lỗi không làm dừng cả lượt: ghi lỗi của file đó, nạp tiếp file khác, cuối
   lượt in danh sách file thành công và thất bại.

**Hai đường nạp, chung một quy trình:**

- **Lệnh nạp** cho cả thư mục `documents/`: dùng để chạy sẵn trước buổi demo.
- **Tải lên qua web** ở trang "Tài liệu": file được lưu vào `documents/` rồi nạp đúng
  file đó. Việc nạp chạy nền; trang "Tài liệu" hiện trạng thái từng file (đang xử lý,
  xong, lỗi kèm lý do) và tự cập nhật. Trong lúc đó trang hỏi đáp vẫn dùng được.

Kiểm tra khi tải lên: chỉ nhận `.pdf` và `.docx`; giới hạn dung lượng (người build chọn,
cỡ vài chục MB); tên file được làm sạch để không ghi ra ngoài `documents/`; file trùng
tên thì thay file cũ và nạp lại.

### 5.2a Tài liệu mẫu

Người build tạo sẵn một bộ tài liệu mẫu trong repo (nội dung tự viết, không phải tài
liệu thật), để chạy sẵn và để có thứ tải lên lúc demo:

- ít nhất hai file tiếng Việt và một file tiếng Anh; có cả PDF và .docx
- ít nhất một file có bảng số liệu, để thấy bước dựng lại bảng
- tất cả đều có lớp chữ (không có file scan)
- nội dung là quy định, chính sách nội bộ của một công ty giả định, đủ dài để có nhiều trang
- một file mẫu để riêng, **không** nạp sẵn, dành cho việc tải lên trực tiếp lúc demo
- kèm bộ câu hỏi thử (mục 6) viết theo đúng nội dung các file này

### 5.3 Hỏi đáp

1. Tạo vector cho câu hỏi, lấy khoảng 6 đoạn gần nhất.
2. Gửi câu hỏi và các đoạn đã đánh số cho DeepSeek với yêu cầu: chỉ dùng các đoạn này;
   gắn số nguồn `[n]` cho từng ý; với mỗi nguồn đã dùng, chép nguyên văn một đoạn trích
   ngắn; nếu các đoạn không chứa câu trả lời thì nói rõ là không tìm thấy.
3. Câu trả lời hiện dần trên màn hình.
4. Kiểm tra đoạn trích bằng code: sau khi chuẩn hóa Unicode và khoảng trắng, đoạn trích
   phải nằm trong đúng đoạn tài liệu mà nó dẫn tới. Đoạn trích không khớp thì không hiện;
   nguồn đó chỉ hiện tên file và số trang, kèm ghi chú "không xác minh được đoạn trích".
5. Câu trả lời không dẫn nguồn nào được coi là "không tìm thấy".

### 5.4 Giao diện

Trang hỏi đáp:

```
┌──────────────────────────────────────────────────┐
│ Hỏi đáp tài liệu                     [Tài liệu]  │
├──────────────────────────────────────────────────┤
│ Thời hạn hoàn tiền đặt cọc là bao lâu?   [Hỏi]   │
├──────────────────────────────────────────────────┤
│ Thời hạn hoàn tiền là 14 ngày kể từ ... [1][2]   │
│                                                  │
│ Nguồn                                            │
│ [1] hop-dong.pdf · trang 3                       │
│     "…bên B hoàn trả trong vòng 14 ngày…"        │
│ [2] quy-dinh.docx · trang 7 (bản PDF)            │
│     "…"                                          │
└──────────────────────────────────────────────────┘
```

Trang "Tài liệu": ô tải file lên ở trên cùng, bên dưới là danh sách file (tên, số trang,
số đoạn, trạng thái). Bấm vào một file để xem từng trang, với hai cột cạnh nhau: chữ gốc
rút ra và markdown DeepSeek dựng lại. Trang bị đánh dấu ở bước kiểm tra con số được làm
nổi. Bấm vào một nguồn ở trang hỏi đáp sẽ mở đúng trang đó tại đây. Không hiển thị file
PDF gốc và không có trình xem PDF.

### 5.5 Xử lý lỗi

- Thiếu `DEEPSEEK_API_KEY` hoặc `DEEPSEEK_API_BASE`: báo rõ ngay khi khởi động.
- Chưa nạp tài liệu nào: trang hỏi đáp hướng dẫn chạy lệnh nạp hoặc tải file lên.
- Lỗi khi gọi DeepSeek lúc hỏi: hiện thông báo dễ hiểu, không hiện dấu vết lỗi kỹ thuật.

## 6. Kiểm thử

- Test đơn vị cho lõi với mô hình ngôn ngữ và mô hình tạo vector giả: cắt đoạn (bảng
  không bị cắt, số trang đúng); bỏ qua file không đổi; nạp lại file đổi; một file lỗi
  không dừng cả lượt; trang không có chữ bị đánh dấu; kiểm tra con số bắt được markdown
  thiếu số; đoạn trích bịa bị loại, đoạn trích thật (kể cả khác dạng Unicode và khoảng
  trắng) được giữ; không có nguồn thì thành "không tìm thấy"; tải lên từ chối loại file
  lạ, file quá lớn và tên file cố ghi ra ngoài `documents/`.
- Một bộ câu hỏi thử chạy tay trên tài liệu mẫu, có ít nhất một câu mà tài liệu **không**
  có câu trả lời.

## 7. Thành phần cụ thể

Nguồn: `docs/agent-work/research/2026-11-17-ruby-rag-stack.md` và
`docs/agent-work/research/2026-11-17-deepseek-text-extraction.md`.
Tất cả là lựa chọn của người thiết kế dựa trên hai bản tra cứu đó.

| Việc | Chọn | Ghi chú |
|---|---|---|
| Image nền | `ruby:3.4-slim-trixie` | Ruby 4.0 đã có nhưng chưa xác nhận được các gem native chạy trên đó |
| Đổi .docx → PDF | LibreOffice trong container (`libreoffice-writer-nogui`, `fonts-noto-core`) | Chỉ PDF đã dựng trang mới có số trang thật |
| Rút chữ từ PDF | `pdftotext -layout` (gói `poppler-utils`), chạy một lần mỗi file, tách trang theo ký tự `\f` | Chuẩn hóa Unicode về NFC và khoảng trắng. Trang có dưới khoảng 20 chữ cái coi là không có lớp chữ (ngưỡng ước lượng) |
| Gọi DeepSeek từ Ruby, hiện dần | `Net::HTTP` thuần, gọi `/chat/completions` kiểu OpenAI, tự đọc SSE (bỏ dòng bắt đầu bằng `:`, dừng ở `[DONE]`) | Không thêm gem: ít rủi ro nhất với endpoint nội bộ. `ruby-openai` tự nối `/v1` vào địa chỉ nên dễ lệch với gateway |
| Mô hình DeepSeek cho bước dựng lại và bước trả lời | `deepseek-flash`, tắt chế độ suy nghĩ bằng `reasoning: {enabled: false}` | Tên mô hình đổi được qua biến môi trường. Chat chỉ nhận chữ, không nhận PDF. Endpoint công ty là cổng LiteLLM trước OpenRouter: nó từ chối trường `thinking` của DeepSeek gốc (HTTP 400) và nhận `reasoning: {enabled: false}` (đã đo: chữ đầu tiên sau 1,5 giây, so với 6,8 giây khi để suy nghĩ). Người dùng đã duyệt đổi này. Nếu sau này gọi thẳng DeepSeek thì đổi lại thành `thinking: {type: "disabled"}` |
| Trích nguồn | Các đoạn gửi đi đánh số `[S1]`, `[S2]`… kèm tên file và trang; mô hình chép nguyên văn đoạn trích cho từng ý; câu cố định `NOT_FOUND` khi không có câu trả lời | DeepSeek không có tính năng trích nguồn. Không dùng JSON mode cho câu trả lời, để còn hiện dần được |
| Tạo vector | gem `informers ~> 1.3`, mô hình `Xenova/multilingual-e5-small` (q8, 384 chiều, khoảng 118 MB, có tiếng Việt) | Bắt buộc thêm tiền tố `"passage: "` cho đoạn và `"query: "` cho câu hỏi. Mô hình tải một lần và giữ trong volume |
| Kho lưu | Postgres `pgvector/pgvector:pg18-trixie`, gem `pg` + `pgvector`, cột `vector(384)`, khoảng cách cosine | Không dùng `neighbor` vì nó chỉ dành cho Rails |
| Web | `sinatra ~> 4.2`, `puma`, `rackup`; câu trả lời hiện dần bằng SSE | Sinatra 4.1+ chặn tên host lạ (403): cần khai báo host được phép |

Nếu một điểm thử dưới đây thất bại mà không có phương án thay thế ghi sẵn, người build
dừng lại và hỏi người dùng, không tự đổi thành phần.

**Chưa được kiểm chứng, người build phải thử sớm (trước khi xây phần còn lại):**

1. Endpoint DeepSeek của công ty: gọi được `/chat/completions`; tên mô hình `deepseek-flash`
   có tồn tại ở đó không; có tắt được chế độ suy nghĩ không; có hiện dần từng phần
   hay gom lại rồi mới trả. Mọi mô tả API ở trên là của DeepSeek công khai, chưa thử trên
   endpoint này.
2. `informers` chạy được bản q8 của `multilingual-e5-small` trên cả amd64 và arm64.
3. LibreOffice dựng đúng dấu tiếng Việt với `fonts-noto-core`, và kích thước image chấp nhận được.
4. Công cụ rút chữ giữ đúng dấu tiếng Việt và cột của bảng.
5. Giới hạn độ dài đầu vào của e5 (nhớ là 512 token, chưa kiểm lại): đoạn cắt phải ngắn hơn giới hạn này.
6. Chất lượng tìm kiếm tiếng Việt của e5-small trên tài liệu mẫu. Nếu kém, đổi sang
   `multilingual-e5-base`; số chiều vector phải là một hằng số duy nhất để đổi được.

## 8. Quyết định của ai

**Người dùng quyết định:** file PDF và Word; demo cho manager; người dùng cuối chỉ hỏi và
nhận trả lời; cách A; Ruby; Docker; chạy sẵn được và có chỗ tải tài liệu lên trên giao
diện; dùng tài liệu mẫu tự tạo; chỉ dùng DeepSeek qua key và endpoint của công ty; đọc
file theo cách 1, không OCR.

**Người thiết kế tự chọn (có thể sửa):** nạp tải lên chạy nền, có trạng thái; nội dung
và thành phần bộ tài liệu mẫu (mục 5.2a); lõi Ruby thuần tách khỏi web; đổi .docx sang
PDF để giữ số trang; mỗi câu hỏi độc lập; lấy khoảng 6 đoạn; web chỉ mở trên localhost;
người trình bày chuẩn bị máy trước (không tự nạp khi khởi động); số trang là số thứ tự
trang PDF; bấm nguồn mở trang "Tài liệu" chứ không mở PDF gốc; kho lưu truyền vào lõi từ
ngoài; lưu cả chữ gốc và markdown, hiện hai cột; kiểm tra con số sau khi dựng lại; kiểm
tra đoạn trích bằng code; tên biến trong `.env`; thử thất bại thì dừng và hỏi; README có
một mục ngắn mô tả cách đưa lõi vào hệ thống thật.

**Để người build quyết định:** tên lớp và cách chia file; kích thước đoạn; lời nhắc gửi
DeepSeek; cách trình bày chi tiết của giao diện.

**Chưa biết:** ngày demo. Kế hoạch không phụ thuộc vào nó; nếu gấp thì cắt phần trau
chuốt giao diện trước.
