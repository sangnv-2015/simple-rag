# Early spike results

| Spike | Result | Notes |
|---|---|---|
| 1 DeepSeek endpoint | PASS (arch aarch64) | `POST {base}/chat/completions`, model `deepseek-flash` accepted (resolves to deepseek-v4.1-flash). Request body uses `reasoning: {enabled: false}`; non-stream HTTP 200, no `reasoning_content`; stream 50 events over 5.37 s |
| 2 Embedder (q8, dim 384, norm 1.0, relevant > unrelated) | PASS | aarch64 and x86_64 (amd64 under emulation) |
| 3 LibreOffice html->docx->pdf, Vietnamese fonts | PASS (arch aarch64) | font LiberationSerif; NFC round trip equal. `tmp/spikes/vi-1.png` still needs a human look for missing marks |
| 4 Table extraction | PASS (arch aarch64; check loosened) | see below |
| 5 Input length | PASS (arch aarch64 measured; x86_64 run used the earlier 953-char sample, 241 tokens) | exactly 1000 dense Vietnamese chars = 252 tokens (asserted length; varied prose with numbers and proper nouns; the earlier samples were 953 chars and a repeated sentence); exactly 3000-char input (asserted) embeds without error |

## DeepSeek gateway facts
- The gateway rejects `thinking` and `reasoning_effort` (`"none"` and `"low"`) with HTTP 400 (UnsupportedParamsError).
- It accepts `reasoning: {enabled: false}`.
- Without any switch, thinking is on: stream first content 6.79 s, 1551 reasoning chars. With `reasoning: {enabled: false}`: first content 1.53 s, 44 content events, 5.58 s total, 0 reasoning tokens.

## Table check [4]
Check [4] was loosened by controller ruling from ">=2 spaces" to a same-line match, then tightened in fix round 1 to `[ \t]+` (cannot cross lines) and required for each of two tables.
- Both rows, as extracted (aarch64), with one narrow `border="1"` table and one `width="100%"` table in the same document:
  - `[4-info] table 1 row: Nghỉ phép năm                                   12`
  - `[4-info] table 2 row: Nghỉ phép năm                                   12`
- Earlier run with the narrow table alone: `Nghỉ phép năm 12` (single space). In the two-table document the narrow table also showed a wide gap, so pdftotext column alignment depends on the page, not only the table width.

## Chosen values
- `MAX_CHUNK_CHARS` = 1000 (252 tokens, well under the 450 limit).
- Image `app` size: 1.04GB.

## Task 12: first real end-to-end run (real endpoint, model `Xenova/multilingual-e5-small` dim 384, real Postgres)
- Ingest (all three files in one `bin/ingest` call; per-file wall time was not measured, the model download plus the whole first run was not timed). Pages / chunks / pages that fell back to raw text (number check):
  - quy-che-nghi-phep.pdf: 4 pages, 8 chunks, 0 fallback
  - quy-dinh-lam-viec-tu-xa.docx: 4 pages, 7 chunks, 0 fallback
  - travel-expense-policy.pdf: 4 pages, 7 chunks, 0 fallback
  - Second `bin/ingest`: `Bỏ qua (không đổi):` all 3 files, 2.1 s wall (includes container start).
- `bin/check_retrieval` (rank of the chunk holding the answer, top 6): ranks 1,1,1,2,1,1,1,1,1,1 (only the fever/9 giờ question is rank 2). Score **10/10 in top 6**, exit 0. The e5-base fallback was not needed.
- `bin/ask` times: seconds from process start (includes ~2 s container and model start) to first output byte, then total.
  - "Ngày phép năm ngoái dùng không hết thì được giữ lại sang năm nay mấy ngày?" (first byte 3.3 s, total 4.8 s):
    ```
    Theo quy chế, ngày phép chưa dùng hết trong năm được chuyển tối đa 5 ngày sang năm kế tiếp [S1]. Số ngày được chuyển phải được sử dụng trước ngày 31/03 của năm kế tiếp, quá hạn sẽ tự động hết hiệu lực và không được quy đổi thành tiền [S1].
    [1] quy-che-nghi-phep.pdf · trang 2 — "Ngày phép chưa dùng hết trong năm được chuyển tối đa 5 ngày sang năm kế tiếp. Số ngày được chuyển phải được sử dụng trước ngày 31/03 của năm kế tiếp, quá hạn sẽ tự động hết hiệu lực và không được quy đổi thành tiền."
    ```
    quote verified.
  - Table question "What is the hotel limit per night in a Tier 1 city?" (first byte 2.9 s, total 3.5 s):
    ```
    The hotel cap per night in a Tier 1 city is USD 140 [S1].
    [1] travel-expense-policy.pdf · trang 2 — "Tier 1 (capital cities and major financial centres) | USD 140 per night | USD 60 per day"
    ```
    quote verified (table row kept as markdown cells).
  - Unanswerable "Công ty thưởng Tết bao nhiêu tháng lương?" (3.1 s / 3.5 s) and "Does the company pay for employees' gym memberships?" (3.3 s / 3.6 s): terminal shows only `Không tìm thấy thông tin này trong tài liệu.` (the model answered NOT_FOUND, nothing was streamed).
- `bin/check_retrieval` re-run after requiring the hit to come from the question's own file: ranks 1,1,1,2,1,1,1,1,1,1, score **10/10 in top 6** (unchanged).
