# Simple RAG Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small Ruby RAG app, run with Docker, that ingests PDF/.docx (page text extracted locally, structure rebuilt by DeepSeek), answers questions with streamed, verified citations, and can be shown to a manager.

**Architecture:** A plain-Ruby core in `lib/rag/` with two entry points, `Ingest#call(path)` and `Ask#call(question, &on_delta)`. The LLM, embedder, and store are passed in from outside, so tests use fakes. A thin Sinatra app in `web/` (ask page with SSE, documents page with upload and background ingest) wraps the core. Postgres+pgvector is the store. Embeddings run in-process with `informers`. DeepSeek is called with plain `Net::HTTP`.

**Tech Stack:** Ruby 3.4 (`ruby:3.4-slim-trixie`), Docker Compose, `pgvector/pgvector:pg18-trixie`, gems `informers ~> 1.3`, `pg`, `pgvector`, `sinatra ~> 4.2`, `puma`, `rackup`, minitest. `poppler-utils`, LibreOffice (`libreoffice-writer-nogui`, `fonts-noto-core`).

**Spec:** `docs/superpowers/specs/2026-11-17-simple-rag-demo-design.md` (Vietnamese). Research: `docs/agent-work/research/2026-11-17-ruby-rag-stack.md` (ignore its Claude/Anthropic parts) and `docs/agent-work/research/2026-11-17-deepseek-text-extraction.md`.

## Global Constraints

- Ruby, Docker on macOS laptop, amd64 and arm64. Base image `ruby:3.4-slim-trixie`. **Every test or verify command is `docker compose ...`; assume no host Ruby.**
- Only one external service: DeepSeek, configured in `.env` (never committed): `DEEPSEEK_API_KEY`, `DEEPSEEK_API_BASE`, `DEEPSEEK_MODEL` (default `deepseek-flash`). **Never print, log, or commit the key.** Do not run `docker compose config`, `printenv`, or `cat .env` (they expose it). `.env` is gitignored and in `.dockerignore`; `.env.example` is committed.
- No gems beyond: `informers ~> 1.3`, `pg`, `pgvector`, `sinatra ~> 4.2`, `puma`, `rackup`, minitest. No `neighbor`, no `ruby-openai`, no markdown or HTTP gem.
- DeepSeek: `Net::HTTP`, `POST {DEEPSEEK_API_BASE}/chat/completions` (OpenAI style), body includes `thinking: {type: "disabled"}`; read SSE yourself (skip lines starting with `:`, stop at `[DONE]`). Chat takes text only. The company endpoint is a LiteLLM gateway in front of OpenRouter: it returns HTTP 400 for the DeepSeek-native `thinking` field and for `reasoning_effort`; `reasoning: {enabled: false}` is the spelling it accepts (measured in Task 1, approved by the human).
- Embeddings: `Xenova/multilingual-e5-small`, `dtype: "q8"`, 384 dims, prefix `"passage: "` for chunks and `"query: "` for questions. Model name and dimension are each defined once (`Rag::EMBED_MODEL`, `Rag::EMBED_DIM`) so they can be switched to `multilingual-e5-base` / 768.
- Store: `vector(384)` column, cosine distance (`<=>`), exact scan (no index).
- Page numbers are 1-based PDF page numbers. For `.docx` sources the UI says `trang N (bản PDF)`.
- A page with fewer than 20 letters (`\p{L}`) has no text layer. No OCR.
- Retrieval takes about 6 chunks. Sources in prompts are `[S1]`, `[S2]`...; the model copies a verbatim quote per source; fixed sentinel `NOT_FOUND`. No JSON mode for answers (answers stream).
- Quote verification: after NFC and whitespace collapse, the quote must be a substring of the chunk it cites. A quote that fails is not shown; the source shows only file and page plus the note `không xác minh được đoạn trích`.
- A page whose original numbers are not all present in the rebuilt markdown uses the original text instead and is flagged.
- Each question is independent (no conversation memory). Web binds to localhost only (`127.0.0.1:4567` published; Sinatra `host_authorization` allows only localhost hosts; Sinatra 4.1+ returns 403 for other hosts).
- Upload accepts only `.pdf` and `.docx`, has a size limit, sanitises the filename so nothing is written outside `documents/`, and a same-name file replaces the old one and is re-ingested.
- Two commands for the presenter: `docker compose up`, then `docker compose run --rm app bin/ingest`.
- All user-facing UI copy is Vietnamese (copy is given inline in tasks). Code, tests, and comments are English.
- If `.env` is missing, or any spike fails and the spec has no written fallback for it, **STOP and report to the human. Do not swap a component.** The only written fallback is spike 6 (e5-small to e5-base).

## Review Focus

Input classes the spec implies but the per-task tests of the spec's own list do not cover. Each one has a pinning test in the owning task (named in brackets).

1. Upload filenames macOS produces: Unicode NFD names, spaces, diacritics, backslash paths (`..\..\a.pdf`), the same file uploaded again under a differently-normalised name. Expected: one document, not two; the name stays usable in links. [Task 10 sanitiser tests; Task 8 NFC-key test; Task 14 URL test]
2. Odd model replies to a question: `[S9]` out of range, a quote for a source that was never cited, no quotes block at all, `NOT_FOUND` followed by extra prose, a 2-character quote like `14` (matches anywhere), a quote wrapped in curly quotes. Expected: never crash, never show an unverifiable quote, never show raw `NOT_FOUND` or marker text while streaming. [Task 9]
3. Blank or whitespace-only question, and asking before anything is ingested. Expected: friendly Vietnamese message, no call to DeepSeek, no 500. [Task 9, Task 13]
4. DeepSeek misbehaving: blank markdown or markdown wrapped in a code fence during ingest; connection dropped mid-answer. Expected: blank means fall back to original text; a fence is stripped; a dropped stream gives the friendly error, and the partial answer is not presented as final. [Task 4, Task 5, Task 13]
5. Bad files: random bytes named `.pdf`/`.docx`, wrong extension, no output from LibreOffice. Expected: that file is reported as failed with a reason, the batch continues, nothing half-saved. [Task 3, Task 8]

---

## File Structure

```
Dockerfile, docker-compose.yml, Gemfile, Gemfile.lock, config.ru
.env.example, .gitignore, .dockerignore, README.md
bin/test, bin/ingest, bin/ask, bin/check_retrieval, bin/build_samples
lib/rag.rb                 constants, Struct types, Rag::Error, loads lib/rag/*.rb
lib/rag/text.rb            Text.nfc / clean / squash
lib/rag/chunker.rb         Chunker.split
lib/rag/extract.rb         Extract.pages (pdftotext, soffice) + split_pages
lib/rag/deepseek.rb        DeepSeek client (Net::HTTP, SSE)
lib/rag/restructurer.rb    page text -> markdown + number check
lib/rag/embedder.rb        informers wrapper with prefixes
lib/rag/store.rb           Postgres + pgvector store
lib/rag/ingest.rb          ingest orchestration + Report
lib/rag/ask.rb             retrieval, prompt, streaming filter, quote verification
lib/rag/upload.rb          upload validation + sanitising + safe save
lib/rag/config.rb          Config.from_env; Rag.build wiring
web/app.rb, web/worker.rb, web/views/{layout,ask,documents,document}.erb
samples/manifest.yml, samples/src/*.html, samples/questions.yml, samples/upload-demo/
documents/                 generated sample PDFs/.docx (committed, produced by bin/build_samples)
spikes/{deepseek,embed,office}.rb, spikes/RESULTS.md
test/test_helper.rb, test/support/{fakes,fake_store,store_contract,fake_sse_server,office_fixtures,pg_test_db}.rb
test/*_test.rb, test/web/*_test.rb
```

---

### Task 1: Docker scaffold and early spikes

**Files:**
- Create: `.gitignore`, `.dockerignore`, `.env.example`, `Dockerfile`, `docker-compose.yml`, `Gemfile`, `Gemfile.lock`, `bin/test`
- Create: `spikes/deepseek.rb`, `spikes/embed.rb`, `spikes/office.rb`, `spikes/RESULTS.md`

**Interfaces:**
- Consumes: nothing.
- Produces: image `app` (service name `app`, workdir `/app`, repo bind-mounted at `/app`, gems in `/usr/local/bundle`); service `db` (healthcheck `pg_isready`); env `DATABASE_URL=postgres://rag:rag@db:5432/rag` and `TEST_DATABASE_URL=postgres://rag:rag@db:5432/rag_test`; `XDG_CACHE_HOME=/cache` backed by volume `models`; volume `pgdata`; `env_file: [{path: .env, required: false}]` on `app`; port `127.0.0.1:4567:4567`; default command `bundle exec rackup -s puma -o 0.0.0.0 -p 4567 config.ru`; `bin/test [files...]` (runs all `test/**/*_test.rb` when no args, with `-Ilib -Itest`); measured values in `spikes/RESULTS.md`: DeepSeek behaviour, tokens-per-char, the `MAX_CHUNK_CHARS` to use in Task 2, image size.

- [ ] **Step 1: Write the repo hygiene files**
  `.gitignore`: `.env`, `tmp/`, `.DS_Store`. `.dockerignore`: `.env`, `.git`, `tmp/`. `.env.example`: `DEEPSEEK_API_KEY=` (blank), `DEEPSEEK_API_BASE=https://api.deepseek.com` (comment: replace with the company endpoint, no trailing slash), `DEEPSEEK_MODEL=deepseek-flash`.
  Run: `git check-ignore .env` → prints `.env`.

- [ ] **Step 2: Check the human's `.env` exists (do not display it)**
  Run: `test -f .env && echo present || echo MISSING`
  Expected: `present`. If `MISSING`: commit Step 1 files, then **STOP and report**: "Copy `.env.example` to `.env`, fill `DEEPSEEK_API_KEY` and `DEEPSEEK_API_BASE`, then resume at Step 3." Also stop if `.env` lacks either variable (check with `grep -c '^DEEPSEEK_API_KEY=.' .env` and the same for `DEEPSEEK_API_BASE`, expecting `1` each; these print counts, not values).

- [ ] **Step 3: Write Gemfile, Dockerfile, docker-compose.yml, bin/test; build**
  Gemfile gems exactly as in Global Constraints (minitest in a `:test` group). Dockerfile: `FROM ruby:3.4-slim-trixie`; `apt-get install -y --no-install-recommends poppler-utils libreoffice-writer-nogui fonts-noto-core fonts-liberation2 libpq5` (if `bundle install` must compile `pg`, add `build-essential libpq-dev`); `COPY Gemfile Gemfile.lock* ./` then `bundle install`; `WORKDIR /app`. Compose: `db` image `pgvector/pgvector:pg18-trixie`, env `POSTGRES_USER/PASSWORD/DB` = `rag`, volume `pgdata`, healthcheck; `app` `depends_on: db: condition: service_healthy`.
  Run: `docker compose build` → exit 0.

- [ ] **Step 4: Generate `Gemfile.lock` for both architectures**
  Run: `docker compose run --rm app bash -c "bundle install && bundle lock --add-platform x86_64-linux aarch64-linux"`
  Expected: lock written to host; `grep -E '^  (x86_64-linux|aarch64-linux)$' Gemfile.lock` prints both lines. Then `docker compose run --rm app bin/test` → exits 0 with `0 runs` (no tests yet).

- [ ] **Step 5: Spike 2 and 5 (embedder, input length): write and run `spikes/embed.rb`**
  Script: load `Informers.pipeline("embedding", "Xenova/multilingual-e5-small", dtype: "q8")`; embed one Vietnamese query and two passages (one relevant, one unrelated); count tokens with `Tokenizers.from_pretrained("Xenova/multilingual-e5-small").encode(text).tokens.size` for a dense 1000-char Vietnamese passage; embed a 3000-char string.
  Run: `docker compose run --rm app ruby spikes/embed.rb`
  Expected output lines (first run downloads about 118 MB, then is cached in the `models` volume):
  ```
  arch=<aarch64|x86_64>
  [2] q8 model loaded, dim=384: PASS
  [2] vector L2 norm within 1.0 +/- 0.01: PASS
  [6-pre] cos(query, relevant passage) > cos(query, unrelated passage): PASS
  [5] 1000 Vietnamese chars = N tokens: PASS   (PASS when N <= 450)
  [5] 3000-char input embeds without error: PASS
  MAX_CHUNK_CHARS candidate=<1000 if N<=450 else floor(1000*450/N) rounded down to 50>
  ```
  Any FAIL: STOP and report (no written fallback).

- [ ] **Step 6: Spike 3 and 4 (LibreOffice, Vietnamese, tables): write and run `spikes/office.rb`**
  Script: write a small HTML file in `tmp/spikes/` with Vietnamese text containing stacked diacritics (`ệ ữ ặ ớ ẫ`) and a `<table>` (row `Nghỉ phép năm | 12`); convert to `.docx` with `soffice --headless -env:UserInstallation=file:///tmp/lo-profile --infilter="HTML (StarWriter)" --convert-to docx`, then `.docx` to PDF (`--convert-to pdf`); run `pdffonts`, `pdftotext -layout`, and `pdftoppm -png -r 80 -f 1 -l 1` to `tmp/spikes/vi`. Always use `Open3` with argument arrays and the `timeout` utility (120 s).
  Run: `docker compose run --rm app ruby spikes/office.rb`
  Expected:
  ```
  [3] html -> docx -> pdf OK
  [3] pdffonts: <font names>  (must include a Noto or Liberation font): PASS
  [3/4] pdftotext round trip equals source text after NFC: PASS
  [4] table row 'Nghỉ phép năm' keeps its number on the same line after >=2 spaces: PASS
  [3] wrote tmp/spikes/vi-1.png (human: open it, no boxes or missing marks)
  ```
  Then run `docker image ls app --format '{{.Size}}'` and record the size. If the size is over 2 GB (planner's threshold, the spec gives none) or any FAIL: STOP and report. If only the infilter name is wrong, fix the flag; that is not a component swap.

- [ ] **Step 7: Spike 1 (DeepSeek endpoint): write and run `spikes/deepseek.rb`**
  Script uses `Net::HTTP` and reads `ENV["DEEPSEEK_API_KEY"]`, `ENV["DEEPSEEK_API_BASE"]`, `ENV["DEEPSEEK_MODEL"] || "deepseek-flash"`. Exit 2 with `STOP: .env missing or incomplete` if either variable is blank. Never print the key, the Authorization header, or the full base URL (print only HTTP status codes and the model name; on errors print at most 300 chars of the response body). Three checks: (a) non-stream `POST {base}/chat/completions` with `thinking: {type: "disabled"}` and a short prompt; (b) the response has no `reasoning_content` (field forwarded); (c) stream call asking for about 150 words: count `data:` events and the seconds between first and last.
  Run: `docker compose run --rm app ruby spikes/deepseek.rb`
  Expected:
  ```
  [1a] POST /chat/completions HTTP 200, model=deepseek-flash, content non-empty: PASS
  [1b] thinking disabled honoured (no reasoning_content): PASS
  [1c] streaming N events over T s: PASS    (PASS when N >= 5 and T >= 0.3)
  ```
  Any FAIL (404 or 400 on the model name, `reasoning_content` present, events collected into one chunk): STOP and report to the human with the status code and the failing check; do not change the model, the path, or the client approach.

- [ ] **Step 8: Run spikes 2 and 5 on the other CPU architecture**
  Run (pick the arch that `arch=` did not print; `x86_64` is `linux/amd64`, `aarch64` is `linux/arm64`): `DOCKER_DEFAULT_PLATFORM=linux/<other> docker compose run --rm --build app ruby spikes/embed.rb`
  Expected: same PASS lines with the other `arch=`. If the emulator itself crashes (illegal instruction, segfault) that is not proof either way: STOP and report "unverified on <arch>", do not swap anything. Afterwards rebuild native: `docker compose build`.

- [ ] **Step 9: Record results and commit**
  Fill `spikes/RESULTS.md`: one line per spike with PASS/FAIL, arch(es), the DeepSeek facts (model name accepted, path, streaming events/seconds), tokens for 1000 chars, chosen `MAX_CHUNK_CHARS`, image size. No secrets.
  ```bash
  git add .gitignore .dockerignore .env.example Dockerfile docker-compose.yml Gemfile Gemfile.lock bin/test spikes
  git commit -m "chore: docker scaffold and early spikes"
  ```
  Then `git ls-files | grep -c '^\.env$'` → `0`.

---

### Task 2: Text helpers and Chunker

**Files:**
- Create: `lib/rag.rb`, `lib/rag/text.rb`, `lib/rag/chunker.rb`, `test/test_helper.rb`, `test/text_test.rb`, `test/chunker_test.rb`

**Interfaces:**
- Consumes: `MAX_CHUNK_CHARS` value from `spikes/RESULTS.md`.
- Produces:
  - `lib/rag.rb`: `module Rag` with constants `EMBED_MODEL = "Xenova/multilingual-e5-small"`, `EMBED_DIM = 384`, `MAX_CHUNK_CHARS` (from spike, 1000 if untouched), `MIN_LETTERS = 20`, `TOP_K = 6`, `MAX_UPLOAD_BYTES = 30 * 1024 * 1024`, `MIN_QUOTE_CHARS = 10`; `class Error < StandardError`; keyword-init Structs `Page(number, raw_text, markdown, readable, fallback)`, `Chunk(page, position, text, embedding)`, `Doc(id, filename, sha256, status, error, page_count, chunk_count)`, `Hit(filename, page, text, distance)`. It requires every `lib/rag/*.rb` by `Dir` glob (sorted), so later tasks add files without editing it.
  - `Rag::Text.nfc(s) -> String`; `Rag::Text.clean(raw) -> String` (NFC, strip trailing spaces per line, collapse 3+ newlines to one blank line, strip leading and trailing blank lines; inner runs of spaces are kept because they carry table columns); `Rag::Text.squash(s) -> String` (NFC, every `\p{Space}` run including NBSP to one space, stripped).
  - `Rag::Chunker.split(text, max_chars: Rag::MAX_CHUNK_CHARS) -> Array<String>`.
  - `test/test_helper.rb`: sets `$LOAD_PATH`, requires `minitest/autorun`, `rag`, and every `test/support/*.rb`.

- [ ] **Step 1: Write the failing tests**
```ruby
# test/text_test.rb
def test_clean_nfc_rstrip_keeps_column_runs
  assert_equal "Nghỉ phép    12\n\nHết", Rag::Text.clean("Nghỉ phép    12  \n\n\n\nHết\n\n")
end
def test_squash_collapses_nbsp_newlines_and_unicode_form
  assert_equal "Nghỉ phép 12", Rag::Text.squash("  Nghỉ phép\n\t 12 ")
end

# test/chunker_test.rb  (max_chars: 100 unless stated)
def test_blank_input_gives_no_chunks;                assert_equal [], Rag::Chunker.split(" \n\n ")
def test_heading_starts_new_chunk                    # "# A\nx\n\n# B\ny" -> 2 chunks, each begins with its heading
def test_heading_only_chunk_merges_into_next         # "# A\n## B\ntext" -> 1 chunk
def test_paragraphs_pack_up_to_max_and_split_between_paragraphs  # all chunks <= 100, no paragraph cut
def test_table_never_split_and_moves_whole_to_next_chunk
  # 80-char paragraph + 6-row '|' table of 60 chars: table is wholly inside one chunk
def test_oversize_table_stays_one_chunk              # table of 300 chars, max 100 -> exactly 1 chunk, equal to the table
def test_oversize_paragraph_split_loses_nothing      # 450-char paragraph: all chunks <= 100; chunks.join.gsub(/\s/,"") == original.gsub(/\s/,"")
def test_vietnamese_text_is_unchanged                # chunk text equals input slice, diacritics intact
def test_plain_layout_text_splits_on_blank_lines     # raw text without markdown still chunks
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/text_test.rb test/chunker_test.rb`
Expected: errors `cannot load such file -- rag`.

- [ ] **Step 3: Implement `lib/rag.rb`, `Rag::Text`, `Rag::Chunker.split`**
Chunker algorithm: split into blocks on blank lines; consecutive lines starting with `|` are one table block; a line starting with `#` is a heading block. Pack blocks into the current chunk joined by a blank line while `size <= max_chars`. A heading starts a new chunk unless the current chunk holds only headings. A table is never divided, even if alone over `max_chars` (oversize table stays whole; only its embedding gets truncated). A non-table block over `max_chars` is split on line ends, then sentence ends (`. `), then hard-cut at `max_chars`. Drop blank chunks.

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/text_test.rb test/chunker_test.rb`
Expected: `0 failures, 0 errors`.

- [ ] **Step 5: Commit**
```bash
git add lib test
git commit -m "feat: text helpers and chunker"
```

---

### Task 3: PDF and .docx text extraction

**Files:**
- Create: `lib/rag/extract.rb`, `test/extract_test.rb`, `test/support/office_fixtures.rb`

**Interfaces:**
- Consumes: `Rag::Page`, `Rag::Error`, `Rag::MIN_LETTERS`, `Rag::Text.clean`.
- Produces:
  - `Rag::Extract.pages(path) -> Array<Rag::Page>`: `.pdf` runs `pdftotext -layout <abs path> -`; `.docx` is first converted with `timeout 120 soffice --headless -env:UserInstallation=file:///tmp/lo-profile --convert-to pdf --outdir <mktmpdir> <abs path>` and then handled as a PDF; the temp dir is removed afterwards. Always `Open3` with an argument array, never a shell string, always an absolute path. Raises `Rag::Extract::Error < Rag::Error` (Vietnamese message) on an unsupported extension, a non-zero exit, a missing converted PDF, or a timeout (exit 124).
  - `Rag::Extract.split_pages(raw) -> Array<Rag::Page>`: split on `"\f"` (`split("\f", -1)`, drop the trailing empty element), page `number` is the 1-based index, `raw_text = Rag::Text.clean(chunk)`, `readable = raw_text.scan(/\p{L}/).size >= Rag::MIN_LETTERS`, `markdown: nil`, `fallback: false`.
  - `OfficeFixtures.pdf(text)` / `OfficeFixtures.docx(text)` in test support: write a `.txt` into a shared tmpdir and run `soffice --convert-to pdf|docx`; memoised so each is built once per test run.

- [ ] **Step 1: Write the failing tests**
```ruby
# pure
def test_split_pages_numbers_and_drops_trailing_empty
  pages = Rag::Extract.split_pages("Quy định nghỉ phép năm của công ty\fTrang hai có chữ đủ dài để đọc được\f")
  assert_equal [1, 2], pages.map(&:number)
end
def test_page_with_few_letters_is_unreadable        # "  3  \n" and "12345678901234567890123" -> readable false
def test_nfd_input_is_composed_and_columns_kept     # "Nghỉ phép    12 ..." -> "Nghỉ phép    12 ..."
# real poppler + LibreOffice (no network)
def test_pdf_has_several_pages_with_vietnamese_text # OfficeFixtures.pdf(150 lines "Quy định nghỉ phép năm ..."): pages.size >= 2, numbers 1..n, pages.first.raw_text includes "Quy định nghỉ phép năm", readable
def test_docx_is_converted_and_read                 # OfficeFixtures.docx(same text) -> pages.size >= 2, same first-line text
def test_garbage_pdf_raises_extract_error           # random bytes in x.pdf -> Rag::Extract::Error
def test_garbage_docx_raises_extract_error          # random bytes in x.docx -> Rag::Extract::Error, no temp dir left behind
def test_unsupported_extension_raises               # x.txt -> Rag::Extract::Error
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/extract_test.rb`
Expected: `NameError: uninitialized constant Rag::Extract`.

- [ ] **Step 3: Implement `Rag::Extract.pages` and `.split_pages`** as specified in Interfaces. Force UTF-8 and scrub invalid bytes on the `pdftotext` output. Write `OfficeFixtures` first (needed by the tests).

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/extract_test.rb`
Expected: `0 failures, 0 errors` (the soffice tests take several seconds).

- [ ] **Step 5: Commit**
```bash
git add lib/rag/extract.rb test
git commit -m "feat: extract per-page text from pdf and docx"
```

---

### Task 4: DeepSeek client

**Files:**
- Create: `lib/rag/deepseek.rb`, `test/deepseek_test.rb`, `test/support/fake_sse_server.rb`

**Interfaces:**
- Consumes: `Rag::Error`.
- Produces:
  - `Rag::DeepSeek.new(api_key:, base_url:, model: "deepseek-flash", read_timeout: 120)`.
  - `#chat(messages, &on_delta) -> String`. `messages` is `[{role: "user", content: "..."}]`. Without a block: non-stream, returns `choices[0].message.content` (`""` if blank). With a block: `stream: true`, yields each non-empty `choices[0].delta.content` String in order, returns the concatenation. URL is `base_url.chomp("/") + "/chat/completions"` (so a base with a path prefix works); header `Authorization: Bearer <key>`; body has `model`, `messages`, `thinking: {type: "disabled"}`, and `temperature: 0`. No `stream_options`, no `response_format`.
  - `Rag::DeepSeek::Error < Rag::Error`: its message is safe to show, for example `"Không gọi được DeepSeek (HTTP 401)"`, `"Không kết nối được DeepSeek"`, `"DeepSeek ngắt kết nối giữa chừng"`; it never contains the key or the response body (the truncated body, 300 chars, goes to `$stderr`).
  - `FakeSSEServer.start(&handler) { |server| server.url }`: in-process `TCPServer` on port 0; `handler.call(request)` where `request` has `path`, `headers`, `json_body` returns `[status, [chunks...]]`; each chunk is written and flushed as separate TCP writes (so a JSON line can be split mid-way) and the response is chunked or connection-close.

- [ ] **Step 1: Write the failing tests** (all against `FakeSSEServer`)
```ruby
def test_non_stream_returns_content_and_sends_expected_request
  # asserts: path "/v1/chat/completions" for base ".../v1", Authorization "Bearer k", body["reasoning"] == {"enabled"=>false}, no "thinking" key, body["model"], no "stream" key
def test_stream_yields_deltas_in_order_and_returns_concatenation  # "Xin ", "chào" -> yielded ["Xin ", "chào"], returns "Xin chào"
def test_stream_ignores_comments_empty_choices_null_content_and_reasoning  # ": keep-alive", {"choices":[]}, delta content nil, delta reasoning_content only
def test_stream_json_line_split_across_tcp_writes_and_crlf
def test_stream_stops_at_done
def test_http_error_message_has_status_but_not_key_or_body    # 401 with body "secret-key-echo"; assert_equal "Không gọi được DeepSeek (HTTP 401)"; refute_includes message, "k"/"secret"
def test_connection_refused_raises_error                      # closed port -> "Không kết nối được DeepSeek"
def test_stream_cut_before_done_raises_after_yielding_partial # yielded ["Xin "] then Error "DeepSeek ngắt kết nối giữa chừng"
def test_blank_non_stream_content_returns_empty_string
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/deepseek_test.rb`
Expected: `NameError: uninitialized constant Rag::DeepSeek`.

- [ ] **Step 3: Implement `Rag::DeepSeek`**
Net::HTTP with `use_ssl` from the URL scheme; streaming via `res.read_body` into a line buffer (chunk boundaries are arbitrary, split on `\n`, strip `\r`); only `data: ` lines carry events; track whether `[DONE]` was seen to detect a cut stream. Rescue `SocketError`, `Errno::*`, `Net::OpenTimeout`, `Net::ReadTimeout`, `EOFError`, `OpenSSL::SSL::SSLError` and re-raise as `Error`.

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/deepseek_test.rb`
Expected: `0 failures, 0 errors`.

- [ ] **Step 5: Commit**
```bash
git add lib/rag/deepseek.rb test
git commit -m "feat: deepseek chat client with sse streaming"
```

---

### Task 5: Page restructuring and number check

**Files:**
- Create: `lib/rag/restructurer.rb`, `test/restructurer_test.rb`, `test/support/fakes.rb` (FakeLLM)

**Interfaces:**
- Consumes: `Rag::DeepSeek#chat(messages)` shape; `Rag::Text.squash`.
- Produces:
  - `Rag::Restructured = Struct.new(:markdown, :fallback)`.
  - `Rag::Restructurer.new(llm:)`; `#call(raw_text) -> Rag::Restructured`. Sends one user message, non-streaming (no block). Prompt (builder writes the wording, Vietnamese or English) must say: output only markdown for this page; keep headings and lists; rebuild tables as markdown tables; do not summarise, translate, add or remove anything; copy every number exactly; keep headers and footers as they are. Strips a single wrapping code fence (` ```markdown ... ``` ` or ` ``` ... ``` `). `fallback` is `true` when the cleaned reply is blank or `numbers_preserved?` is false; the rejected markdown is still returned in `markdown` (so the documents page can show it). Errors from the LLM propagate.
  - `Rag::Restructurer.numbers_preserved?(raw, markdown) -> Boolean`: tokens are `/\d+(?:[.,]\d+)*/` on `Text.squash` of each side; true iff every raw token appears among the markdown tokens (extra tokens in markdown are fine).
  - `FakeLLM.new { |messages| reply }` in `test/support/fakes.rb`: `#chat(messages, &on_delta)` calls the block; the reply may be a String, an `Array` of delta strings (yielded one by one when a block is given; joined otherwise), or an `Exception` instance (raised). Records `calls` as `[{messages:, streamed:}]`.

- [ ] **Step 1: Write the failing tests**
```ruby
def test_numbers_preserved_true_when_all_present_and_extras_allowed   # raw "Tổng 1.250.000 đồng, 12,5%" ; md has both plus "1." list marker
def test_numbers_preserved_false_when_dropped_or_reformatted          # "1.250.000" -> "1,250,000" and "2025" missing, both false
def test_numbers_ignore_layout_spaces_and_nfd
def test_call_returns_markdown_when_numbers_kept        # fallback false; the page text was in llm.calls.last[:messages]; streamed false
def test_code_fence_is_unwrapped                        # reply "```markdown\n# A\n12\n```" -> markdown "# A\n12"
def test_missing_number_sets_fallback_and_keeps_rejected_markdown
def test_blank_or_whitespace_reply_sets_fallback        # page without any digits, reply "  \n" -> fallback true
def test_llm_error_propagates                           # FakeLLM raises Rag::DeepSeek::Error -> assert_raises
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/restructurer_test.rb`
Expected: `NameError: uninitialized constant Rag::Restructurer`.

- [ ] **Step 3: Implement `Rag::Restructurer` and `FakeLLM`.**

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/restructurer_test.rb`
Expected: `0 failures, 0 errors`.

- [ ] **Step 5: Commit**
```bash
git add lib/rag/restructurer.rb test
git commit -m "feat: restructure pages with number check"
```

---

### Task 6: Embedder

**Files:**
- Create: `lib/rag/embedder.rb`, `test/embedder_test.rb`

**Interfaces:**
- Consumes: `Rag::EMBED_MODEL`.
- Produces: `Rag::Embedder.new(pipe: nil)`: when `pipe` is nil it builds `Informers.pipeline("embedding", Rag::EMBED_MODEL, dtype: "q8")` in the constructor (eager load, so the model downloads at first start and a `docker compose up` or `bin/ingest` shows it). `pipe` is any callable taking an Array of Strings and returning an Array of Float arrays. `#embed_passages(texts) -> Array<Array<Float>>` (prefix `"passage: "`, batches of 32, order kept, `[]` for `[]` without calling the pipe). `#embed_query(text) -> Array<Float>` (prefix `"query: "`). Calls are guarded by one Mutex (the web worker thread and request threads share the instance).

- [ ] **Step 1: Write the failing tests** (fake pipe records its inputs; no model download)
```ruby
def test_passages_get_prefix_and_are_batched_in_order   # 70 texts -> pipe called with sizes [32,32,6], every input starts "passage: ", 70 vectors returned in order
def test_empty_list_does_not_call_pipe
def test_query_gets_query_prefix_and_returns_one_vector  # pipe received ["query: Nghỉ phép?"]
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/embedder_test.rb` → `NameError: uninitialized constant Rag::Embedder`.

- [ ] **Step 3: Implement `Rag::Embedder`.**

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/embedder_test.rb` → `0 failures, 0 errors`.

- [ ] **Step 5: Commit**
```bash
git add lib/rag/embedder.rb test/embedder_test.rb
git commit -m "feat: e5 embedder with prefixes and batching"
```

---

### Task 7: Store (Postgres + pgvector) with a fake and a shared contract

**Files:**
- Create: `lib/rag/store.rb`, `test/support/fake_store.rb`, `test/support/store_contract.rb`, `test/support/pg_test_db.rb`, `test/fake_store_test.rb`, `test/pg_store_test.rb`

**Interfaces:**
- Consumes: `Rag::Page`, `Rag::Chunk`, `Rag::Doc`, `Rag::Hit`, `Rag::EMBED_DIM`.
- Produces `Rag::Store.new(url)` (and `FakeStore.new`, same methods; `FakeStore#search` uses cosine distance over stored vectors):
  - `migrate!` — idempotent: `CREATE EXTENSION IF NOT EXISTS vector`; tables `documents(id serial pk, filename text unique, sha256 text, status text, error text)`, `pages(document_id fk on delete cascade, number int, raw_text, markdown null, readable bool, fallback bool)`, `chunks(document_id fk on delete cascade, page_number int, position int, text, embedding vector(<EMBED_DIM>))`. Register pgvector types after the extension exists (type OIDs are looked up at registration).
  - `find_document(filename) -> Rag::Doc | nil`
  - `start_document(filename:, sha256:) -> Integer` — deletes any existing row with that filename (cascade), inserts status `"processing"`.
  - `finish_document(id, pages:, chunks:) -> nil` — `pages` is `Array<Rag::Page>`, `chunks` is `Array<Rag::Chunk>` with `embedding` set; inserts both and sets status `"done"` in one transaction.
  - `fail_document(id, message) -> nil` — status `"error"`, `error = message`.
  - `documents -> Array<Rag::Doc>` ordered by filename, with `page_count` and `chunk_count`.
  - `pages(filename) -> Array<Rag::Page>` ordered by number (empty array for unknown file).
  - `search(embedding, k) -> Array<Rag::Hit>` nearest first (`distance` ascending), `[]` on an empty store.
  - Statuses are the strings `"processing"`, `"done"`, `"error"`. All real queries run under one `Mutex` on a single `PG::Connection` (Puma threads plus the worker thread).
  - `PgTestDb.url` — ensures database `rag_test` exists (connect to `DATABASE_URL`, `CREATE DATABASE rag_test`, rescue `PG::DuplicateDatabase`) and returns `TEST_DATABASE_URL`.
  - `module StoreContract` — tests shared by both stores; includers define `make_store` (fresh, empty, migrated). Vectors in tests are unit vectors `v(i)` = `EMBED_DIM` zeros with 1.0 at index `i`.

- [ ] **Step 1: Write the contract tests** (`test/support/store_contract.rb`, included by `FakeStoreTest` and `PgStoreTest`)
```ruby
def test_migrate_is_idempotent                      # store.migrate! twice, no error
def test_start_then_find_shows_processing           # find_document("a.pdf").status == "processing"; unknown file -> nil
def test_finish_stores_pages_chunks_and_counts      # documents -> [Doc filename "a.pdf" status "done" page_count 2 chunk_count 3]
def test_start_again_replaces_old_data              # second start_document("a.pdf") -> pages("a.pdf") == [], documents has one row, status processing
def test_fail_sets_error_status_and_message
def test_search_nearest_first_with_file_and_page    # chunks at v(0) page 1 and v(1) page 2; search(v(1), 1) -> Hit filename "a.pdf", page 2, text, distance ~ 0.0; search(v(0), 5) distances ascending
def test_search_on_empty_store_returns_empty
def test_pages_returns_raw_markdown_and_flags_in_order  # unreadable page has markdown nil, readable false; fallback page has fallback true
def test_documents_ordered_by_filename
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/fake_store_test.rb test/pg_store_test.rb`
Expected: `NameError` for `FakeStore` / `Rag::Store`.

- [ ] **Step 3: Implement `FakeStore` first, then `Rag::Store`.** `PgStoreTest#make_store` builds `Rag::Store.new(PgTestDb.url)`, runs `migrate!`, and truncates all three tables (`TRUNCATE documents RESTART IDENTITY CASCADE`). Use `pgvector` gem helpers (`Pgvector::PG.register_vector`) and parameterised queries only (no string-built SQL with values).

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/fake_store_test.rb test/pg_store_test.rb`
Expected: `0 failures, 0 errors` (this starts the `db` service).

- [ ] **Step 5: Commit**
```bash
git add lib/rag/store.rb test
git commit -m "feat: pgvector store with fake and shared contract tests"
```

---

### Task 8: Ingest orchestration

**Files:**
- Create: `lib/rag/ingest.rb`, `test/ingest_test.rb`
- Modify: `test/support/fakes.rb` (add `FakeEmbedder`, `FakeExtractor`)

**Interfaces:**
- Consumes: `Rag::Extract.pages` shape, `Rag::Restructurer`, `Rag::Chunker.split`, `Embedder#embed_passages`, store methods from Task 7, `Rag::Text.nfc`.
- Produces:
  - `Rag::Ingest.new(llm:, embedder:, store:, extractor: Rag::Extract)`; builds `Restructurer.new(llm:)` itself.
  - `#call(path) -> Rag::Report` — `path` is a directory (every `*.pdf` / `*.docx`, case-insensitive, sorted by name) or one file. `Rag::Report = Struct.new(:ok, :skipped, :failed)` (`ok`/`skipped`: filenames; `failed`: `[[filename, message]]`); `#failed? -> Boolean`; `#summary -> String` (lines `OK: ...`, `Bỏ qua (không đổi): ...`, `Lỗi: <file> — <message>`; for an empty directory `Không có file .pdf/.docx nào trong <dir>`).
  - Per-file flow: key = `Rag::Text.nfc(File.basename(path))`; `sha256` of the file bytes; skip if the stored doc has the same sha and status `"done"` (status `"error"` or `"processing"` with the same sha is re-processed); `id = store.start_document`; `extractor.pages(path)`; if no page is readable raise `Rag::Error, "file scan, không đọc được"`; for each readable page `Restructurer#call`, set `page.markdown` and `page.fallback`; chunk text = `fallback ? raw_text : markdown`; chunks from `Chunker.split` with `page`, 0-based `position`; one `embed_passages` call for the whole file; `finish_document`. Any `StandardError` (including `Extract::Error`, `DeepSeek::Error`) goes to `fail_document(id, e.message)` and into `report.failed`; nothing is stored for a failed file except the error row; the batch continues. A path with another extension is reported as failed (`"Chỉ nhận file .pdf và .docx."`).
  - `FakeEmbedder`: `embed_passages(texts)` / `embed_query(text)` return hashed bag-of-words vectors of size `Rag::EMBED_DIM` (`Zlib.crc32(word) % EMBED_DIM` buckets, counts, L2-normalised); records inputs. `FakeExtractor.new("a.pdf" => [Rag::Page...] | Exception)`: `pages(path)` looks up `File.basename(path)`, records calls.

- [ ] **Step 1: Write the failing tests** (FakeStore, FakeLLM replying with the page text prefixed by `# ` so numbers survive; real files written in a tmpdir so sha256 works)
```ruby
def test_ingests_file_and_stores_pages_chunks_with_page_numbers   # doc "done"; every chunk page in 1..n; embedder received all chunk texts once
def test_unchanged_file_is_skipped_without_llm_or_extractor_calls  # second call: report.skipped == ["a.pdf"], llm.calls.size and extractor.calls.size unchanged
def test_changed_file_replaces_old_data                            # new bytes -> old chunks gone, one doc, new page text present
def test_failed_file_does_not_stop_the_batch                       # extractor raises Extract::Error for bad.pdf: report.failed == [["bad.pdf", msg]], good.pdf in ok, bad.pdf status "error" with message and no pages, summary lists both
def test_unreadable_page_is_marked_and_not_sent_to_llm             # page 2 readable false: stored readable false, markdown nil, no chunks with page 2, llm called once per readable page
def test_file_with_only_unreadable_pages_fails_with_scan_message   # failed message "file scan, không đọc được"
def test_page_with_dropped_number_uses_raw_text_for_chunks         # llm drops "1.250.000": page.fallback true, chunk text contains "1.250.000", stored markdown is the rejected one
def test_error_status_with_same_hash_is_retried_not_skipped
def test_llm_error_midway_stores_no_pages_or_chunks                # second page raises DeepSeek::Error: status "error", pages("a.pdf") == [], message from the error
def test_directory_takes_only_pdf_and_docx_case_insensitive_sorted # a.PDF, b.docx, c.txt ignored; ok order ["a.PDF","b.docx"]
def test_empty_directory_reports_no_files
def test_single_file_path_and_unsupported_extension_path
def test_nfd_named_file_with_same_content_is_the_same_document     # ingest "Quy dinh.pdf" (NFC) then an NFD-named copy: skipped, store.documents.size == 1, key is NFC
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/ingest_test.rb` → `NameError: uninitialized constant Rag::Ingest`.

- [ ] **Step 3: Implement `Rag::Ingest`, `Rag::Report`, and the added fakes.**

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/ingest_test.rb` → `0 failures, 0 errors`.

- [ ] **Step 5: Commit**
```bash
git add lib/rag/ingest.rb test
git commit -m "feat: ingest orchestration with hash skip and per-file failures"
```

---

### Task 9: Ask (retrieval, prompt, streaming, quote verification)

**Files:**
- Create: `lib/rag/ask.rb`, `test/ask_test.rb`

**Interfaces:**
- Consumes: `Embedder#embed_query`, `Store#search(embedding, k) -> [Hit]`, `LLM#chat(messages, &on_delta)`, `Rag::Text.squash`, `Rag::MIN_QUOTE_CHARS`.
- Produces:
  - `Rag::Source = Struct.new(:n, :filename, :page, :quote)` (`quote` is nil unless verified; `n` is the `S` number the model used); `Rag::Answer = Struct.new(:text, :found, :sources)` (`text` is the answer without the quotes block).
  - `Rag::Ask::QUOTES_MARKER = "\n<<QUOTES>>\n"`, `Rag::Ask::NOT_FOUND = "NOT_FOUND"`.
  - `Rag::Ask.new(llm:, embedder:, store:, k: Rag::TOP_K)`; `#call(question, &on_delta) -> Rag::Answer`. Errors from the LLM propagate (the web layer shows the friendly message).
  - Flow: `hits = store.search(embedder.embed_query(question), k)`; if `hits` is empty return `Answer.new("", false, [])` without calling the LLM. One user message containing: the rules, each hit as `[S1] file=<filename> page=<n>` + chunk text + `[/S1]`, and the question. Rules (builder words them) must say: use only these sources; put `[S<n>]` after each claim; answer in the question's language; after the answer print exactly the marker line `<<QUOTES>>` then one line per used source `[S<n>] <verbatim quote copied from that source>`; if the sources do not contain the answer reply exactly `NOT_FOUND`.
  - Streaming filter (decides what reaches `on_delta`): accumulate the reply; forward only text before `QUOTES_MARKER`; hold back the longest trailing part of the buffer that is a proper prefix of the marker; forward nothing while the left-stripped buffer is a proper prefix of `NOT_FOUND` or starts with `NOT_FOUND`. After the stream ends, flush any held-back text that turned out not to be a marker (not for `NOT_FOUND`).
  - Parsing: split the full reply on the marker. Cited sources are the distinct `[S<n>]` found in the answer part in order of first appearance, kept only for `1..hits.size`. Quote lines `/^\[S(\d+)\]\s*(.+)$/` from the quotes part; a single pair of wrapping straight or curly double quotes is stripped; a quote counts only for a cited source, and is verified when `Text.squash(quote).size >= MIN_QUOTE_CHARS` and `Text.squash(hit.text).include?(Text.squash(quote))` (case-sensitive); the source's `quote` is the squashed quote, otherwise nil. `found` is false when the answer text starts with `NOT_FOUND` or no valid source is cited.

- [ ] **Step 1: Write the failing tests** (FakeStore preloaded with chunks, FakeEmbedder, FakeLLM)
```ruby
def test_answer_with_verified_quote_and_sources
  # reply "Hoàn tiền trong 14 ngày [S1].\n<<QUOTES>>\n[S1] bên B hoàn trả trong vòng 14 ngày"
  # store chunk "... bên B hoàn trả trong vòng 14 ngày kể từ ..." (a.pdf p3)
  # -> found true; sources == [Source(1,"a.pdf",3,"bên B hoàn trả trong vòng 14 ngày")]; text == "Hoàn tiền trong 14 ngày [S1]."
def test_prompt_contains_numbered_sources_question_and_sentinel  # llm.calls.last message includes "[S1]", "file=a.pdf", "page=3", chunk text, the question, "NOT_FOUND", "<<QUOTES>>"; embedder got the question once
def test_stream_never_leaks_marker_or_quotes     # FakeLLM deltas ["Hoàn tiền [S1].\n<<QU", "OTES>>\n[S1] bên B ..."]: forwarded text joined == "Hoàn tiền [S1]." exactly
def test_stream_flushes_held_back_text_that_was_not_a_marker  # deltas ["Giá 5\n<<", "3 [S1]"]: "\n<<" is held back as a marker prefix, then released; forwarded joined == "Giá 5\n<<3 [S1]"
def test_fabricated_quote_is_dropped_but_source_listed          # quote not in chunk -> Source(1,"a.pdf",3,nil), found true
def test_quote_matches_across_unicode_form_and_whitespace       # chunk has NFD and "\n  " and NBSP, quote typed NFC with single spaces -> quote returned, verified
def test_curly_quotes_around_quote_are_stripped_then_verified
def test_short_quote_is_not_verified                            # quote "14" -> nil
def test_no_citation_means_not_found                            # reply "Có lẽ 14 ngày." -> found false
def test_not_found_sentinel_emits_nothing_and_is_not_found      # deltas ["NOT_", "FOUND"] -> forwarded [], found false; "NOT_FOUND\nGhi chú..." also found false
def test_out_of_range_source_is_ignored                         # "[S9]" only -> found false; "[S1] ... [S9]" -> sources only S1
def test_quote_for_uncited_source_is_ignored                    # quotes block lists S2 but answer cites only S1
def test_missing_quotes_block_gives_sources_with_nil_quotes
def test_empty_store_returns_not_found_without_calling_llm      # llm.calls.empty?
def test_llm_error_propagates
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/ask_test.rb` → `NameError: uninitialized constant Rag::Ask`.

- [ ] **Step 3: Implement `Rag::Ask`, `Rag::Source`, `Rag::Answer`.**

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/ask_test.rb` → `0 failures, 0 errors`.

- [ ] **Step 5: Commit**
```bash
git add lib/rag/ask.rb test/ask_test.rb
git commit -m "feat: ask with streaming filter and quote verification"
```

---

### Task 10: Upload validation and safe save (trust boundary)

**Files:**
- Create: `lib/rag/upload.rb`, `test/upload_test.rb`

**Interfaces:**
- Consumes: `Rag::Error`, `Rag::MAX_UPLOAD_BYTES`, `Rag::Text.nfc`.
- Produces:
  - `Rag::Upload::Rejected < Rag::Error` (message is Vietnamese and shown to the user).
  - `Rag::Upload.sanitize(filename) -> String` — NFC; replace `\` with `/`, keep only the part after the last `/`; drop NUL and control characters; replace every character outside `[\p{L}\p{N}._ ()-]` with `_`; strip leading dots and spaces; stem capped at 100 chars; extension lowercased; raises `Rejected` `"Chỉ nhận file .pdf và .docx."` unless the final extension is `.pdf` or `.docx` (so `a.pdf.exe`, `.pdf`, no extension, and `.txt` are all rejected).
  - `Rag::Upload.save(filename:, io:, dir:, max_bytes: Rag::MAX_UPLOAD_BYTES) -> String` (absolute path). Sanitises, copies `io` in chunks into a temp file inside `dir` while counting bytes, raises `Rejected` `"File quá lớn (tối đa 30 MB)."` as soon as the count exceeds `max_bytes` (the temp file is deleted), then `File.rename` onto the final name (replaces a same-name file, or a symlink itself, never a symlink's target). Final guard: the resolved path must start with `File.realpath(dir) + "/"`, else `Rejected`.

- [ ] **Step 1: Write the failing tests** (tmpdirs; `StringIO` bodies)
```ruby
def test_accepts_pdf_and_docx_and_lowercases_extension          # "Report.DOCX" -> "Report.docx"
def test_rejects_other_extensions                               # "a.exe", "a.txt", "noext", "a.pdf.exe", ".pdf", "a.pdf/" -> Rejected "Chỉ nhận file .pdf và .docx."
def test_traversal_names_land_inside_dir
  # "../../etc/passwd.pdf" -> "passwd.pdf"; "..\\..\\evil.pdf" -> "evil.pdf"; "/tmp/x.pdf" -> "x.pdf"; "a\0b.pdf" has no NUL
  # every returned path start_with?(File.realpath(dir) + "/"); File.exist?(File.join(dir, "..", "evil.pdf")) is false
def test_existing_symlink_is_replaced_not_followed             # dir/x.pdf -> outside/target; save "x.pdf": outside/target unchanged, dir/x.pdf is a regular file
def test_size_limit_exact_ok_and_one_over_rejected_without_leftovers  # max_bytes: 10; 10 bytes ok; 11 bytes -> Rejected "File quá lớn (tối đa 30 MB)." and Dir.children(dir) empty
def test_same_name_replaces_content
def test_vietnamese_name_with_spaces_kept_and_nfd_becomes_nfc   # "Quy dịnh nghỉ phép (2026).pdf" -> "Quy định nghỉ phép (2026).pdf"
def test_other_special_characters_become_underscore             # "a<b>:c.pdf" -> "a_b__c.pdf"
def test_long_stem_is_capped_and_extension_kept
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/upload_test.rb` → `NameError: uninitialized constant Rag::Upload`.

- [ ] **Step 3: Implement `Rag::Upload.sanitize` and `.save`.**

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/upload_test.rb` → `0 failures, 0 errors`.

- [ ] **Step 5: Commit**
```bash
git add lib/rag/upload.rb test/upload_test.rb
git commit -m "feat: upload validation and safe save"
```

---

### Task 11: Sample documents and question set

**Files:**
- Create: `samples/manifest.yml`, `samples/src/*.html`, `samples/questions.yml`, `bin/build_samples`, `test/samples_test.rb`, `documents/*` (generated), `samples/upload-demo/*` (generated)

**Interfaces:**
- Consumes: `Rag::Extract.pages`, `Rag::Text.squash`.
- Produces:
  - `samples/manifest.yml`: list of `{src: <html file>, out: <path under documents/ or samples/upload-demo/>, lang: vi|en, preload: true|false}`. The invented company's regulations and policies; no real documents.
  - Set (planner's choice of content, builder writes the prose): `quy-che-nghi-phep` (vi, `.pdf`, preload, has a table of annual leave days by years of service); `quy-dinh-lam-viec-tu-xa` (vi, `.docx`, preload); `travel-expense-policy` (en, `.pdf`, preload, has a per-diem table by city tier); `chinh-sach-hoan-tien` (vi, `.docx`, `preload: false`, goes to `samples/upload-demo/`, has a refund-rate-by-days table). Each at least 3 pages (use headings and enough prose or explicit page breaks) and has a text layer.
  - `samples/questions.yml`: list of `{question, file, contains, answerable: true|false, after_upload: true|false}` where `contains` is a short phrase (inside one paragraph or one table cell) that appears verbatim in the source. At least 8 answerable preloaded questions: at least 3 Vietnamese phrased with different words than the document, 2 English, 2 about table cells; 1 about the upload-demo file (`after_upload: true`); at least 2 unanswerable (one Vietnamese, one English) about things the documents do not state.
  - `bin/build_samples`: for each manifest entry runs `soffice --infilter="HTML (StarWriter)" --convert-to docx` (as proven in spike 3/4) and, for `.pdf` outputs, `--convert-to pdf` from that docx, via the same `Open3` and `timeout` rules as `Rag::Extract`; then fails (non-zero) unless every output has at least 3 pages (`pdfinfo`/`Rag::Extract.pages`) and every page is readable. Generated outputs are committed (LibreOffice output is not byte-reproducible, but the script is the source of truth; never edit the binaries by hand).

- [ ] **Step 1: Write the failing test** (`test/samples_test.rb`, reads committed files, no network)
```ruby
def test_manifest_covers_spec_mix          # >= 2 vi and >= 1 en preloaded; both .pdf and .docx among preloaded; exactly one preload:false file and it is not under documents/
def test_every_sample_has_three_readable_pages  # Rag::Extract.pages(file): size >= 3, all readable
def test_every_answerable_question_phrase_is_in_its_file  # squash(all page text of q.file).include?(squash(q.contains))
def test_question_set_has_required_mix     # >= 8 answerable preloaded, >= 2 unanswerable, exactly the upload-demo question flagged after_upload
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/samples_test.rb` → fails (manifest missing).

- [ ] **Step 3: Write the HTML sources, manifest, questions, and `bin/build_samples`; generate**
Run: `docker compose run --rm app bin/build_samples` → prints one `built <out> (<n> pages)` line per file and exits 0. Create `documents/` and `samples/upload-demo/` outputs with it.

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/samples_test.rb` → `0 failures, 0 errors`.

- [ ] **Step 5: Commit**
```bash
git add samples documents bin/build_samples test/samples_test.rb
git commit -m "feat: sample documents, question set, and reproducible build script"
```

---

### Task 12: Config, wiring, CLI tools, first real end-to-end run

**Files:**
- Create: `lib/rag/config.rb`, `test/config_test.rb`, `bin/ingest`, `bin/ask`, `bin/check_retrieval`

**Interfaces:**
- Consumes: everything in Tasks 2 to 10; `.env` values; `samples/questions.yml`.
- Produces:
  - `Rag::ConfigError < Rag::Error`; `Rag::Config = Struct.new(:api_key, :api_base, :model, :database_url, :documents_dir)`; `Rag::Config.from_env(env = ENV)`: raises `ConfigError` with a Vietnamese message naming each missing or blank variable (`Thiếu biến môi trường: DEEPSEEK_API_KEY, DEEPSEEK_API_BASE. Hãy điền trong file .env (xem .env.example).`); `model` defaults to `deepseek-flash`; `database_url` from `DATABASE_URL`; `documents_dir` from `DOCUMENTS_DIR` or `<repo>/documents`.
  - `Rag::System = Struct.new(:config, :store, :ingest, :ask)`; `Rag.build(config = Config.from_env) -> Rag::System`: builds `Store` (and `migrate!`), `Embedder.new`, `DeepSeek`, `Ingest`, `Ask`.
  - `bin/ingest [path...]` (default `documents/`): prints `report.summary` per path; exit status 1 if any `failed?`. A `ConfigError` prints its message and exits 2 with no backtrace.
  - `bin/ask "question"`: streams the answer to stdout, then prints sources (`[n] file · trang N` plus quote or `không xác minh được đoạn trích`) or `Không tìm thấy thông tin này trong tài liệu.`
  - `bin/check_retrieval`: for each answerable, preloaded question in `samples/questions.yml`: embed the question, `store.search(.., Rag::TOP_K)`, find the first rank (1-based) whose chunk text squashes to include `contains`; print `<rank|MISS> <question>`; print `N/M in top 6`; exit 1 if `N/M < 0.8` (planner's threshold; the spec gives none).

- [ ] **Step 1: Write the failing test**
```ruby
def test_missing_key_and_base_are_named_in_message   # from_env({}) raises ConfigError; message includes "DEEPSEEK_API_KEY" and "DEEPSEEK_API_BASE"
def test_blank_value_counts_as_missing               # {"DEEPSEEK_API_KEY"=>"  ", "DEEPSEEK_API_BASE"=>"http://x"}
def test_defaults_and_values                         # model "deepseek-flash" when DEEPSEEK_MODEL absent; documents_dir ends with "documents"
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/config_test.rb` → `NameError: uninitialized constant Rag::Config`.

- [ ] **Step 3: Implement `Rag::Config`, `Rag.build`, and the three bin scripts** (all `chmod +x`).

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test` → full suite `0 failures, 0 errors`.

- [ ] **Step 5: Real run, part 1 (needs `.env`; first use of the real endpoint through our client and the real embedder)**
  If `.env` is missing, STOP and report. Run: `docker compose run --rm app bin/ingest`
  Expected: model download on first run, then `OK:` lists the 3 preloaded sample files and no `Lỗi:` lines. Run it again: expected `Bỏ qua (không đổi):` lists the same 3 files and finishes in seconds. If a file fails because the endpoint rejects a field our client sends, STOP and report (spike 1 should have caught it).

- [ ] **Step 6: Real run, part 2 (spike 6: Vietnamese retrieval quality) and one real question**
  Run: `docker compose run --rm app bin/check_retrieval`
  Expected: final line `N/M in top 6` with `N/M >= 0.8`, exit 0. If below: this is the one written fallback. Set `Rag::EMBED_MODEL = "Xenova/multilingual-e5-base"` and `Rag::EMBED_DIM = 768` (only those two constants), run `docker compose down -v` (drops the vector table and the model cache; the base model downloads once), `docker compose run --rm app bin/ingest`, and `bin/check_retrieval` again. Still below: STOP and report.
  Then run: `docker compose run --rm app bin/ask "<one answerable Vietnamese question from samples/questions.yml>"` and `docker compose run --rm app bin/ask "<one unanswerable question>"`.
  Expected: the first prints a streamed answer with `[Sn]` markers and at least one source with a quote; the second prints `Không tìm thấy thông tin này trong tài liệu.` Record the `check_retrieval` score and which model is in use in `spikes/RESULTS.md`.

- [ ] **Step 7: Commit**
```bash
git add lib/rag/config.rb bin test/config_test.rb spikes/RESULTS.md lib/rag.rb
git commit -m "feat: config, wiring, ingest/ask/check_retrieval commands"
```

---

### Task 13: Web, ask page with SSE

**Files:**
- Create: `web/app.rb`, `web/views/layout.erb`, `web/views/ask.erb`, `config.ru`, `test/web/ask_route_test.rb`

**Interfaces:**
- Consumes: `Rag::Ask#call`, `Rag::Answer`, `Rag::Source`, `Store#documents`, `Rag.build`.
- Produces:
  - `Web < Sinatra::Base` with settings `:ask`, `:store`, `:worker`, `:documents_dir`, `:max_upload_bytes` (set by `config.ru` from `Rag.build`; tests use `Class.new(Web) { set ... }` with fakes). `set :host_authorization, permitted_hosts: ["localhost", "127.0.0.1", "[::1]"]`; `set :show_exceptions, false`; `set :erb, escape_html: true`. Tests drive it with `Rack::MockRequest` (no extra gem).
  - `GET /` → ask page. Title `Hỏi đáp tài liệu`, link `Tài liệu` to `/documents`, input and button `Hỏi`. If `store.documents` is empty (no document with status `done`), the page also shows `Chưa có tài liệu nào. Chạy lệnh nạp (docker compose run --rm app bin/ingest) hoặc tải file lên ở trang Tài liệu.`
  - `GET /ask?q=...` → `text/event-stream`, `Cache-Control: no-cache`. Events (each `event: <name>\ndata: <json>\n\n`): `delta` with `{"text": "..."}` per forwarded delta; `done` with `{"found": bool, "text": "...", "sources": [{"n":1,"filename":"..","page":3,"quote":"..|null","docx":bool}]}`; `error` with `{"message": "Không thể trả lời lúc này. Vui lòng thử lại sau."}` for any `StandardError` (no class name, message, or backtrace in the output). Blank or whitespace-only `q` → status 400, `Ask` not called.
  - Client JS (inline in `ask.erb`, `EventSource`, close on `done` or `error`): appends delta text with `textContent` only (never `innerHTML`; answers and quotes are untrusted); shows `[Sn]` as `[n]`; on `done` with `found: false` replaces the text with `Không tìm thấy thông tin này trong tài liệu.`; sources list `[n] <filename> · trang N` (`trang N (bản PDF)` when `docx`), quote in quotes, or the note `không xác minh được đoạn trích` when `quote` is null; each source links to `/documents/<url-encoded filename>?page=N`; on `error` the partial text is cleared and the error message is shown.

- [ ] **Step 1: Write the failing tests** (FakeStore, a `FakeAsk` returning a scripted `Answer` and yielding scripted deltas)
```ruby
def test_index_shows_title_link_and_guidance_when_no_documents
def test_index_has_no_guidance_when_a_document_is_done
def test_ask_streams_deltas_then_done_with_sources  # body has two "event: delta" blocks in order and one "event: done" whose JSON sources[0] == {"n"=>1,"filename"=>"a.docx","page"=>3,"quote"=>"...","docx"=>true}; content type "text/event-stream"
def test_blank_question_is_400_and_ask_not_called   # "q=%20%20" and missing q
def test_ask_error_gives_friendly_event_without_details  # FakeAsk raises Rag::DeepSeek::Error("Không gọi được DeepSeek (HTTP 502)") and, separately, RuntimeError("boom"): body has the friendly message, refute_includes "boom", "RuntimeError", "HTTP 502"
def test_error_after_partial_deltas_still_ends_with_error_event
def test_foreign_host_is_forbidden                  # HTTP_HOST "evil.example" -> 403; "localhost:4567" -> 200
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/web/ask_route_test.rb` → `NameError: uninitialized constant Web`.

- [ ] **Step 3: Implement `web/app.rb`, `layout.erb`, `ask.erb`, `config.ru`**
`config.ru` loads `lib/rag`, `web/app`, calls `Rag.build` (a `ConfigError` aborts startup with its message), sets the settings, and `run Web`. It never ingests at boot.

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test test/web/ask_route_test.rb` → `0 failures, 0 errors`.

- [ ] **Step 5: Smoke the real server**
Run: `docker compose up -d` then `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4567/` → `200`; `curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: evil.example' http://localhost:4567/` → `403`; `curl -sN 'http://localhost:4567/ask?q=<URL-encoded answerable question>'` → shows `event: delta` lines arriving over time, ending with `event: done`. If `.env` is missing, `docker compose logs app` should show the Vietnamese config message and the container exits (expected, not a bug).

- [ ] **Step 6: Commit**
```bash
git add web config.ru test/web
git commit -m "feat: web ask page with sse streaming"
```

---

### Task 14: Web, documents page, upload, page viewer

**Files:**
- Create: `web/worker.rb`, `web/views/documents.erb`, `web/views/document.erb`, `test/web/documents_route_test.rb`, `test/web/worker_test.rb`
- Modify: `web/app.rb`, `config.ru`

**Interfaces:**
- Consumes: `Rag::Upload.save`, `Rag::Upload::Rejected`, `Store#documents`, `Store#pages`, `Rag::Ingest#call(path)`, `Rag::Text.nfc`.
- Produces:
  - `Worker.new { |path| ... }` in `web/worker.rb`: one thread, one `Queue`, so jobs run strictly one at a time (LibreOffice must not run concurrently). `#enqueue(path)`; `#pending -> Array<String>` (NFC basenames queued or running). An exception inside a job is rescued and logged to `$stderr` (message only) and the thread continues.
  - Routes: `GET /documents` lists each file with name, `Số trang`, `Số đoạn`, status (`đang chờ` for names in `worker.pending`, else `đang xử lý` / `xong` / `lỗi: <reason>`), the upload form (field `file`, button `Tải lên`), and `<meta http-equiv="refresh" content="3">` only while any file is pending or `processing`. `POST /documents` calls `Upload.save(filename:, io:, dir: settings.documents_dir, max_bytes: settings.max_upload_bytes)`, then `worker.enqueue(path)` and redirects `303` to `/documents`; `Rejected` renders the list again with status 422 and the message; a missing `file` field is 400 with `Chọn một file để tải lên.`. `GET /documents/:filename` (optional `?page=N`) looks the file up in the store by NFC-normalised name (never the filesystem); unknown is 404. It shows page by page, two columns `Chữ gốc` and `Markdown (DeepSeek dựng lại)`, markdown shown as preformatted source text (no markdown gem); fallback pages are highlighted with `Đã dùng chữ gốc vì markdown thiếu số liệu`; unreadable pages show `Trang không đọc được (không có lớp chữ)`; every page has `id="page-N"` and the requested page is highlighted. All content is HTML-escaped by the ERB setting.
  - `config.ru` builds `Worker.new { |path| system.ingest.call(path) }`.

- [ ] **Step 1: Write the failing tests**
```ruby
# worker_test
def test_jobs_run_one_at_a_time_in_order          # two blocking jobs: second does not start until first is released
def test_pending_lists_queued_and_running_names_then_empties
def test_failing_job_does_not_kill_worker          # first job raises, second still runs
# documents_route_test (FakeStore, fake worker, tmpdir documents_dir, small max_upload_bytes)
def test_list_shows_name_counts_and_status_labels  # done / processing / error "lỗi: file scan, không đọc được" / queued "đang chờ"
def test_list_refreshes_only_while_something_is_in_progress
def test_upload_valid_pdf_saves_enqueues_and_redirects  # 303 to /documents; file exists in tmpdir; worker.enqueued == [that path]
def test_upload_rejects_other_extension_and_too_large   # 422 with the Vietnamese message; tmpdir empty; nothing enqueued
def test_upload_traversal_name_stays_inside_documents_dir # filename "../../evil.pdf" -> saved as tmpdir/evil.pdf; nothing outside tmpdir
def test_upload_without_file_is_400
def test_viewer_shows_two_columns_flags_and_unreadable_page
def test_viewer_escapes_html_in_content                  # raw_text and markdown contain "<script>alert(1)</script>": response has "&lt;script&gt;", not "<script>alert"
def test_viewer_unknown_file_is_404
def test_viewer_handles_spaces_diacritics_and_nfd_request # file "Quy định nghỉ phép.pdf" reachable via URL-encoded NFC and NFD paths
```

- [ ] **Step 2: Run to verify failure**
Run: `docker compose run --rm app bin/test test/web/worker_test.rb test/web/documents_route_test.rb` → `NameError` / 404 failures.

- [ ] **Step 3: Implement the worker, routes, and views**

- [ ] **Step 4: Run to verify pass**
Run: `docker compose run --rm app bin/test` → full suite `0 failures, 0 errors`.

- [ ] **Step 5: Manual smoke in a browser (needs `.env`, ingested sample set)**
  `docker compose up -d`; open `http://localhost:4567/documents`; upload `samples/upload-demo/*.docx`; watch status go `đang xử lý` then `xong` without reloading; open the file, see the two columns and the rebuilt table; go back to `/` and ask the upload-demo question. Also upload a `.txt` (expect the Vietnamese rejection) and a random file renamed `.pdf` (expect `lỗi: ...` status with a reason, other files unaffected). Record anything odd in `spikes/RESULTS.md`.

- [ ] **Step 6: Commit**
```bash
git add web config.ru test/web spikes/RESULTS.md
git commit -m "feat: documents page, upload with background ingest, page viewer"
```

---

### Task 15: README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: the commands and files above. Produces nothing code depends on. Written in Vietnamese (the spec and UI are Vietnamese; the presenter reads it); command lines and identifiers stay as in the code.

- [ ] **Step 1: Write `README.md` with these sections** (each short)
  1. What it is, in three lines, and the privacy note (document text is sent to the DeepSeek endpoint at ingest and at answer time; the web only listens on localhost).
  2. Setup: `cp .env.example .env`, fill `DEEPSEEK_API_KEY` and `DEEPSEEK_API_BASE` (and optionally `DEEPSEEK_MODEL`).
  3. Prepare the machine before the demo, exactly two commands: `docker compose up` (first run builds the image and pulls Postgres), then `docker compose run --rm app bin/ingest` (downloads the embedding model once, ingests `documents/`; running it again skips unchanged files). Expected output of ingest.
  4. Demo script: ask 2 answerable questions from `samples/questions.yml` (one phrased with different words, one about a table), open a source and show the page view with raw versus rebuilt markdown, ask an unanswerable question to show `Không tìm thấy`, upload `samples/upload-demo/*.docx` live and ask about it. Note that `.docx` pages are pages of the converted PDF.
  5. Hand-run question set: how `samples/questions.yml` is meant to be used (expected file and phrase per question) and `bin/check_retrieval`.
  6. Developing: `docker compose run --rm app bin/test`, `bin/build_samples` (regenerates sample files; do not edit them by hand), `bin/ask "..."` for the core without the web.
  7. Troubleshooting: 403 means a non-localhost host name; scan PDFs are reported unreadable (no OCR); to reset data and cache `docker compose down -v`; changing the embedding model needs `down -v` and a re-ingest; a file stuck at `đang xử lý` after a restart is fixed by running `bin/ingest` again.
  8. `Đưa lõi vào hệ thống thật` (short): the core is `lib/rag.rb` and `lib/rag/*.rb` (copy them; not packaged as a gem); entry points `Rag::Ingest.new(llm:, embedder:, store:).call(path)` and `Rag::Ask.new(llm:, embedder:, store:).call(question) { |delta| ... }`; the three injected collaborators and the exact methods each must offer (`llm.chat(messages, &on_delta)`, `embedder.embed_passages/embed_query`, the store methods listed in Task 7); replace `Rag::Store` with the host system's own persistence by implementing those methods; replace `Rag::DeepSeek` with the host's LLM client; keep the quote check and the number check, they are what makes answers trustworthy; list the gems and system packages the core needs (`informers`, `pg`, `pgvector`, `poppler-utils`, LibreOffice only for `.docx`); what the demo skips (auth, scale, OCR).

- [ ] **Step 2: Verify every command in the README runs**
  Run each of the documented commands once from a clean checkout state (`docker compose up -d`, `docker compose run --rm app bin/ingest`, `docker compose run --rm app bin/test`, `docker compose run --rm app bin/ask "..."`) and confirm the output matches what the README says. Fix the README, not the code, when they differ.

- [ ] **Step 3: Commit**
```bash
git add README.md
git commit -m "docs: readme with run, ingest, demo script, and integration notes"
```

---

## Self-review notes (spec coverage, filled in by the plan author)

- Spec 5.1/5.2 steps 1 to 8 → Tasks 3, 5, 2, 6, 7, 8. Two ingest paths → Tasks 12 (CLI), 14 (upload). Hash skip, re-ingest, scan pages, number check, per-file failure → Task 8.
- 5.2a samples and question set → Task 11. 5.3 ask → Task 9. 5.4 UI → Tasks 13, 14. 5.5 errors → Tasks 12 (config), 13 (no documents, friendly error).
- Spec 6 tests: chunker (Task 2), skip/re-ingest/failure/unreadable/numbers (Tasks 5, 8), quotes (Task 9), upload extension, size, traversal (Task 10, Task 14).
- Spec 7 unverified items 1 to 5 → Task 1; item 6 → Task 12 Step 6.
- Names used across tasks were checked: `Rag::Page`, `Rag::Chunk`, `Rag::Doc`, `Rag::Hit` (Task 2) are the types the store (Task 7), ingest (Task 8), and web (Tasks 13, 14) use; `Store` method names are identical in Tasks 7, 8, 12, 14; `Ask` returns `Rag::Answer` with `Rag::Source` in Tasks 9, 12, 13.

## Done when

### Automated
- `docker compose build` → exit 0
- `docker compose run --rm app bin/test` → `0 failures, 0 errors` (no test touches DeepSeek or downloads a model)
- `docker compose run --rm app bin/ingest` → lists the 3 preloaded samples under `OK:`; a second run lists them under `Bỏ qua (không đổi):`
- `docker compose run --rm app bin/check_retrieval` → `N/M in top 6` with `N/M >= 0.8`, exit 0
- `docker compose up -d`, then `curl -s -o /dev/null -w '%{http_code}' http://localhost:4567/` → `200`; with `-H 'Host: evil.example'` → `403`
- `git ls-files | grep -c '^\.env$'` → `0`; `git grep -nE 'sk-[A-Za-z0-9]{10,}'` → no output
- `docker compose run --rm app bin/build_samples` → exit 0 and `bin/test test/samples_test.rb` passes

### Manual
- In the browser at `http://localhost:4567`: the answer appears progressively, not all at once; each answer shows file, page, and a quote; an unanswerable question shows `Không tìm thấy thông tin này trong tài liệu.`
- Clicking a source opens the right page in the documents viewer; `.docx` sources read `trang N (bản PDF)`; a page flagged by the number check is visibly highlighted.
- Live upload of the demo `.docx` shows `đang xử lý` then `xong` on its own, and the main page keeps working meanwhile.
- `tmp/spikes/vi-1.png` shows correct Vietnamese diacritics and a table (spike 3/4).
- A human reads `spikes/RESULTS.md` and accepts the image size and the DeepSeek behaviour notes.
