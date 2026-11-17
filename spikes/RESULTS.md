# Early spike results

| Spike | Result | Notes |
|---|---|---|
| 1 DeepSeek endpoint | PASS | `POST {base}/chat/completions`, model `deepseek-flash` accepted (resolves to deepseek-v4.1-flash). Request body uses `reasoning: {enabled: false}`; non-stream HTTP 200, no `reasoning_content`; stream 50 events over 5.37 s |
| 2 Embedder (q8, dim 384, norm 1.0, relevant > unrelated) | PASS | aarch64 and x86_64 (amd64 under emulation) |
| 3 LibreOffice html->docx->pdf, Vietnamese fonts | PASS | font LiberationSerif; NFC round trip equal. `tmp/spikes/vi-1.png` still needs a human look for missing marks |
| 4 Table extraction | PASS (check loosened) | see below |
| 5 Input length | PASS | 1000 dense Vietnamese chars = 241 tokens (varied prose with numbers and proper nouns; an earlier repeated-sentence sample gave 228); 3000-char input embeds without error |

## DeepSeek gateway facts
- The gateway rejects `thinking` and `reasoning_effort` (`"none"` and `"low"`) with HTTP 400 (UnsupportedParamsError).
- It accepts `reasoning: {enabled: false}`.
- Without any switch, thinking is on: stream first content 6.79 s, 1551 reasoning chars. With `reasoning: {enabled: false}`: first content 1.53 s, 44 content events, 5.58 s total, 0 reasoning tokens.

## Table check [4]
Check [4] was loosened by controller ruling from ">=2 spaces" to `\s+` between label and number.
- Narrow auto-width table row: `Nghỉ phép năm 12`
- `[4-info] full-width table row: Nghỉ phép năm                                   12`

## Chosen values
- `MAX_CHUNK_CHARS` = 1000 (241 tokens, well under the 450 limit).
- Image `app` size: 1.04GB.
