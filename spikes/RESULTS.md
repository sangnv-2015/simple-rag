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
