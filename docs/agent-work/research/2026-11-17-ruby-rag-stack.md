---
date: 2026-11-17
topic: Concrete Ruby + Docker stack for a small local-embedding RAG demo (Claude parse + answer, PDF/docx, vi/en)
git_commit: 2a99e1e
status: complete
---
## Answer
Use the official `anthropic` gem (2.9.0, Ruby >= 3.2). Convert .docx to PDF with LibreOffice so every file goes through one Claude "document block" parse path with real page numbers. Embed locally in-process with `informers` + multilingual-e5-small (384-d, int8 ONNX ~118 MB). Store vectors in Postgres (`pgvector/pgvector:pg18-trixie`, multi-arch) via `pg` + `pgvector` gem. Serve with Sinatra 4.2.1 + Puma, streaming SSE. At answer time pass retrieved chunks as `search_result` blocks with citations enabled. Citations and structured outputs conflict (400), so "not found" must be done by prompt, not JSON schema.

## Key findings

### Q1 Anthropic Ruby SDK, PDF, models
- Official gem `anthropic`, latest 2.9.0 (rubygems API, checked 2026-11-17). Ruby >= 3.2.0. Uses net/http + connection_pool. API version `2026-10-21` is used from SDK 2.0.0. — https://platform.claude.com/docs/en/cli-sdks-libraries/sdks/ruby ; https://github.com/anthropics/anthropic-sdk-ruby
- (a) PDF base64 (verified Ruby example in docs): `content: [{type: "document", source: {type: "base64", media_type: "application/pdf", data: [File.binread(p)].pack("m0")}}, {type: "text", text: "..."}]` — https://platform.claude.com/docs/en/build-with-claude/pdf-support
- (a) Files API (no beta header needed now): `file = anthropic.files.upload(file: Anthropic::FilePart.new(Pathname(path), content_type: "application/pdf"))` then `source: {type: "file", file_id: file.id}` — https://platform.claude.com/docs/en/build-with-claude/files . Uploaded files are workspace-wide and persist until deleted (500 MB max each); for a demo base64 is simpler, no cleanup.
- (b) Streaming: `stream = anthropic.messages.stream(max_tokens:, messages:, model:)`; `stream.text.each { |t| print t }` for text only, or `stream.each { |event| ... }` for raw events — SDK docs page above.
- PDF limits: 600 pages per request (100 if context window < 1M tokens); request size 128 MB on first-party API; standard PDF, no password/encryption. Dense PDFs can exhaust context before page limit; each page is processed as an image (so also costs image tokens). — pdf-support page.
- .docx: NOT accepted in a document block. Docs: "Binary formats such as .xlsx or .docx are not supported in document blocks, so convert them to text or PDF first." For .docx with images: convert to PDF first. — pdf-support and files pages.
- Models (docs "Models overview", current lineup): `claude-haiku-5-5` ($0.10+/$0.50+ per MTok, "high-volume extraction"), `claude-sonnet-5-5` ($2/$10, "best combination of speed and intelligence"), `claude-opus-5-5` ($4/$20), `claude-fable-5-2` ($8/$40). All 1M context, 128K max output. Haiku 5.5, Sonnet 5.5, Opus 5.5 all support PDF, citations, search results. Ruby constants like `Anthropic::Model::CLAUDE_OPUS_5_5` appear in docs; symbol/string IDs also accepted (`model: :"claude-opus-5-5"`). Retirement not before Sept/Oct 2027. — https://platform.claude.com/docs/en/models/overview
- Sonnet 5.5 note: Models API reports `thinking.types.disabled.supported = false` (adaptive thinking). Not a blocker; just do not send `thinking: {type: "disabled"}`.

### Q2 Citations for own chunks
- Yes. Two supported routes: `search_result` blocks (top-level in a user message or inside tool results) and custom-content `document` blocks. Docs even say: "if you want Claude to be able to cite specific sentences from your RAG chunks, put each RAG chunk into a plain text document ... custom content documents [for] no further chunking." — https://platform.claude.com/docs/en/build-with-claude/citations ; https://platform.claude.com/docs/en/build-with-claude/search-results
- search_result request shape (verified Ruby example in docs): `{type: "search_result", source: "<any stable string>", title: "...", content: [{type: "text", text: "<chunk>"}], citations: {enabled: true}}` placed in the user message `content` array before the question text block. `source` can be any string e.g. `kb://article-1234`, so encode `file.pdf#page=5` or a chunk id there.
- Response shape: text blocks with `citations: [{type: "search_result_location", cited_text, source, title, search_result_index, start_block_index, end_block_index}]`. `search_result_index` counts search_result blocks in request order, so map back to your chunk row (file, page, passage). `cited_text` is the quoted passage and does not count as output tokens. Claude cites whole content blocks, not substrings; split chunk into several text blocks (e.g. per paragraph) for finer quotes.
- Custom document route: citation `type: "content_block_location"`, fields `document_index`, `document_title`, `start_block_index`, `end_block_index` (exclusive).
- Rules: citations must be enabled on all or none of the documents/search results in a request; search_result only in user messages/tool results; text only.
- Streaming: works. Citations arrive as `citations_delta` inside `content_block_delta` events, one citation each, appended to the current text block's `citations`. — citations page "Streaming support".
- CONFLICT: citations + structured outputs (`output_config.format`) => 400 error. Docs: "Citations cannot be used together with structured outputs." — citations page. Also: a prompt asking for JSON only may yield few/no citations.
- Ruby SDK support for `search_result` / `citations_delta` typed events: the docs show Ruby examples for search_result (hash params), so requests work. NOT verified: exact Ruby event class names for `citations_delta` in `stream.each`; plan a 10-line smoke test (`stream.each { |e| p e.type }`). Hash params work regardless (docs: "Hashes work, but are not typesafe").

### Q3 .docx in Docker
- Claude does not take .docx, so choose: LibreOffice headless -> PDF, or extract text in Ruby.
- Page numbers: .docx stores no fixed pagination (flow layout; fact from format, no source fetched; inference for consequence). Only a render (LibreOffice -> PDF) yields page numbers. docx gem (v0.13.3 on rubygems) and pandoc give text/structure but no pages. Anthropic docs also recommend converting docx to PDF for image content and say this "allows using citations from the PDF document."
- Debian trixie packages (packages.debian.org, LibreOffice 25.2.3): `libreoffice-writer-nogui` (installed ~30 MB) pulls `libreoffice-core-nogui` (installed ~105 MB) plus dependencies; use `--no-install-recommends`. Total image growth is my estimate: several hundred MB (not measured; measure with `docker build` once). Do not install the full `libreoffice` metapackage.
- Command (standard LibreOffice CLI, not freshly sourced): `soffice --headless --convert-to pdf --outdir <dir> <file.docx>`.
- Pitfalls (inference from general LibreOffice behavior, not sourced here): (1) install fonts, e.g. `fonts-noto-core` (~42 MB installed) and `fonts-liberation2`/`fonts-dejavu-core`, else Vietnamese diacritics may fall back or render as boxes and page breaks shift vs Word; (2) soffice needs a writable HOME / `-env:UserInstallation=file:///tmp/lo` and does not like concurrent runs on one profile, so convert serially; (3) first start is slow (~seconds); (4) page numbers are LibreOffice's pagination, which can differ from Word's. Surface this to users as "page in converted PDF".
- Alternative cheaper route (no page numbers): extract text with `docx` gem, send as plain text; cite by paragraph/section instead. Fewer moving parts but fails the "page" citation requirement.

### Q4 Local embeddings
- `informers` gem 1.3.0 (2026-04-15), Ruby >= 3.3 (dropped < 3.3 in 1.3.0), deps `onnxruntime >= 0.9` (0.11.9, has aarch64-linux and x86_64-linux platform gems) and `tokenizers >= 0.6` (0.7.0 has aarch64-linux and x86_64-linux gems). So arm64 and amd64 both get prebuilt native gems on glibc Debian (rubygems API). — https://rubygems.org/gems/informers ; https://github.com/ankane/informers ; CHANGELOG
- Informers: `Informers.pipeline("embedding", "<hf model>", dtype: "q8")` (variants fp32, fp16, int8, uint8, q8, q4, q4f16, bnb4); model must have an ONNX file at `onnx/model.onnx` (or `model_file_name:`); prefixes are the caller's job ("passage: "/"query: " for e5). Cache dir `Informers.cache_dir` (default `$XDG_CACHE_HOME/informers` or `~/.cache/informers`); `INFORMERS_OFFLINE` env disables remote. Mount a volume at the cache dir so the model downloads once. README does not list multilingual-e5 or bge-m3 as examples, so compatibility with that exact model is UNVERIFIED until smoke-tested (XLM-R tokenizer; e5 Xenova exports have standard files).
- multilingual-e5-small (intfloat, MIT): lists `vi` in its languages, 12 layers, hidden 384 so 384-d, vocab 250k. Card: "Each input text should start with 'query: ' or 'passage: ', even for non-English texts." Max 512 tokens (known from card; not re-verified this session). ONNX at `Xenova/multilingual-e5-small`: model.onnx 470 MB fp32; model_int8/quantized/uint8 118 MB; fp16 235 MB. — https://huggingface.co/intfloat/multilingual-e5-small ; https://huggingface.co/Xenova/multilingual-e5-small/tree/main/onnx
- multilingual-e5-base: hidden 768 so 768-d, same prefixes, same 8 ONNX variants at `Xenova/multilingual-e5-base` (sizes not fetched; roughly 3x small, inference).
- bge-m3 (BAAI, MIT): 1024-d, 8192-token context, multilingual; no query prefix needed (dense). `Xenova/bge-m3` ONNX: model.onnx is 607 kB stub + 2.27 GB external data (needs informers >= 1.2.0 external-data support, which exists); int8 568 MB; q4f16 700 MB. Heavy on CPU for a demo; better long-context chunking though.
- Sidecars: HF text-embeddings-inference runs on CPU, but arch-specific tags: `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9` (x86_64) vs `:cpu-arm64-1.9` (aarch64), no Metal in Docker; supports XLM-RoBERTa/E5 (lists multilingual-e5-large-instruct); bge-m3 as embedder not confirmed. Endpoints `/embed`, OpenAI-style `/v1/embeddings`. Ollama: `/api/embed` with `{model, input}` returning L2-normalized vectors; docs page names only `embeddinggemma`; whether bge-m3 is in the Ollama library not verified here. Either adds a second service plus per-arch tag/pull step. — https://github.com/huggingface/text-embeddings-inference ; https://docs.ollama.com/capabilities/embeddings
- Vietnamese quality: multilingual-e5 lists vi and was evaluated on MTEB vi tasks (MassiveIntent vi etc.); no head-to-head retrieval numbers for e5-small vs bge-m3 on Vietnamese were collected. Inference: bge-m3 > e5-base > e5-small in quality; e5-small is the fastest CPU option and adequate for a demo.

### Q5 Vector store
- Image: `pgvector/pgvector:pg18-trixie` (also `pg18`, `0.8.7-pg18-trixie`; bookworm variants exist). Docker Hub manifests list amd64 and arm64 (~170 MB). pgvector v0.8.7. Enable per DB: `CREATE EXTENSION vector;` Index: `CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops);` (unnecessary for a demo-size corpus; exact scan is fine). — https://github.com/pgvector/pgvector ; Docker Hub API
- Ruby access: `neighbor` gem (1.2.0) is ActiveRecord/Rails-oriented (README documents only Rails generators and `has_neighbors`; no Sequel/non-Rails instructions). For a non-Rails Sinatra app use `pgvector` gem 0.3.3 ("Supports pg and Sequel"): `registry = PG::BasicTypeRegistry.new.define_default_types; Pgvector::PG.register_vector(registry); conn.type_map_for_results = ...`. — https://github.com/pgvector/pgvector-ruby ; https://github.com/ankane/neighbor
- sqlite-vec: gem `sqlite-vec` 0.1.9; README warns "sqlite-vec is a pre-v1, so expect breaking changes!"; arm64 Linux prebuilt gem status not verified. Single file, no extra container, but loading an extension in Ruby's sqlite3 needs the gem and `enable_load_extension`.
- Verdict: Postgres adds one container but healthcheck + volume are routine in compose, and the image is multi-arch and documented; sqlite-vec saves a container but pre-v1 and extension-loading quirks. Inference.

### Q6 Web layer
- Sinatra 4.2.1 (2025-10-10; deps rack >= 3.0, < 4, rack-session, rack-protection 4.2.1, mustermann, tilt, logger). `rackup` no longer depends on WEBrick; Sinatra recommends Puma (`gem install sinatra rackup puma`). Puma 8.1.2; Rack 3.2.8. — rubygems API; https://github.com/sinatra/sinatra README + CHANGELOG
- Streaming: `stream do |out| out << "data: ...\n\n" end` ; README says SSE is supported but concurrency depends on server; with non-streaming servers body is sent at once; does not work with Shotgun; check `out.closed?` before writing; `keep_open` leaves stream open. — Sinatra README "Streaming Responses"
- Gotchas (partly inference): set `content_type "text/event-stream"`, `cache-control: no-cache`, `X-Accel-Buffering: no` if a proxy is ever added; Puma thread pool holds one thread per open stream (default 5 threads; fine for a one-user demo); run `bind '0.0.0.0'` inside Docker, not localhost; Sinatra 4.1+ `host_authorization` defaults to `.localhost`, `.test` and IPs in development mode, so a Docker service name like `http://app:4567` from another container gets 403 unless you set `set :host_authorization, permitted_hosts: [...]` (changelog 4.1.0); do not use rerun/Shotgun for streaming; browser `EventSource` is GET only, so pass the question as a query string or use `fetch` + ReadableStream for POST. Citations arrive late in each text block, so stream `citations_delta` events as separate SSE event names.

### Q7 Ruby / Docker image
- Ruby 4.0.9 (2026-10-23) and 3.4.12 and 3.3.13 are all current stable patch releases; 4.1.0-preview1 (2026-10-12) is preview. The page does not state EOL dates. — https://www.ruby-lang.org/en/downloads/releases/
- Official Docker Hub `ruby`: `4.0-slim-trixie` (also `4.0.9-slim-trixie`) multi-arch including amd64 and arm64 (~80 MB compressed); likewise `3.4-slim-trixie` exists (not individually checked). Debian trixie matches libreoffice 25.2.3 package listing used above. Alpine is a bad fit (onnxruntime/tokenizers prefer glibc; musl gems exist only for some).
- Version constraint: informers needs Ruby >= 3.3; anthropic >= 3.2. So 3.3, 3.4, 4.0 all satisfy.

## Options / tradeoffs
| Option | Pros | Cons | When to pick |
|---|---|---|---|
| docx -> PDF via LibreOffice | One parse path, real pages, Claude vision on layout/images | Adds hundreds of MB, fonts, serial conversion | Page citations required (they are) |
| docx text via docx gem | Tiny, fast | No pages; tables/images weaker | If page for docx may be dropped |
| informers + e5-small int8 | No extra container, 118 MB, 384-d, vi supported | Smoke test needed; ONNX CPU slower than TEI | Default |
| TEI / Ollama sidecar | Faster, any model, HTTP | Second service, per-arch tag (TEI) | If informers fails smoke test or want bge-m3 |
| pgvector (pg + pgvector gem) | Multi-arch official image, SQL, stable | One extra container | Default |
| sqlite-vec | Zero extra container | pre-v1, extension loading, arm64 gem unverified | If compose simplicity beats everything |
| search_result blocks | Native RAG shape, source string maps to chunk, streaming ok | Needs your chunking; no structured-output | Default for answers |
| custom-content document | Same granularity control | Citation lacks `source`; use `document_title`/index | Alternative |

## Recommendation
- Ruby: `ruby:3.4-slim-trixie` (safest for native gems; 4.0-slim-trixie is current stable, switch only after `bundle install` passes on both arches. Reason: onnxruntime/tokenizers prebuilt-gem Ruby-ABI coverage for 4.0 was not verified).
- Gems: `anthropic ~> 2.9`, `informers ~> 1.3`, `sinatra ~> 4.2`, `puma`, `rackup`, `pg`, `pgvector`.
- docx: LibreOffice `libreoffice-writer-nogui` + `fonts-noto-core` + `fonts-liberation2` -> PDF; PDFs sent base64 as `document` block to `claude-haiku-5-5` for structured per-page text/markdown (JSON via prompt or structured outputs is OK at ingest since citations are off there).
- Embeddings: `Xenova/multilingual-e5-small`, dtype q8, prefixes "passage: " / "query: ", 384-d, cosine, cache volume.
- DB: `pgvector/pgvector:pg18-trixie`, table with file, page, chunk text, vector(384).
- Answer: `claude-sonnet-5-5`, top-k chunks as `search_result` blocks (source `"<file>#p<page>"`, title file name, citations enabled), system prompt: answer only from results, else reply "not found in the documents". No structured outputs on this call. Stream via `messages.stream`, forward as SSE through Sinatra `stream`.
- Not-found detection is prompt-based plus empty-citation check (inference): if the final text has no citations, show "not found" state.

## Open questions
- informers + `Xenova/multilingual-e5-small` q8 not smoke-tested (no install allowed); tokenizers/onnxruntime prebuilt gems for Ruby 4.0 unverified.
- Exact Ruby SDK event class for `citations_delta` in `stream.each` not verified.
- LibreOffice docker image size and Vietnamese font rendering are estimates, not measurements.
- Vietnamese retrieval quality comparison (e5-small vs base vs bge-m3) not found in a primary source; evaluate on a few real docs.
- Whether Haiku 5.5 PDF parsing quality is sufficient for Vietnamese scans/tables is untested; fall back to Sonnet 5.5 for ingest.
- Max token length 512 for e5 not re-verified this session; chunk to ~200-300 tokens.

## Sources
- https://platform.claude.com/docs/en/cli-sdks-libraries/sdks/ruby — Ruby SDK docs, read 2026-11-17
- https://github.com/anthropics/anthropic-sdk-ruby — README (gem anthropic ~> 2.9.0)
- https://platform.claude.com/docs/en/build-with-claude/pdf-support — limits, base64/Files examples
- https://platform.claude.com/docs/en/build-with-claude/files — Files API, docx note
- https://platform.claude.com/docs/en/build-with-claude/citations — citations, streaming, structured-output conflict
- https://platform.claude.com/docs/en/build-with-claude/search-results — search_result blocks
- https://platform.claude.com/docs/en/models/overview — model IDs, pricing
- https://rubygems.org/api/v1 (anthropic 2.9.0, informers 1.3.0, sinatra 4.2.1, puma 8.1.2, rack 3.2.8, pgvector 0.3.3, neighbor 1.2.0, onnxruntime 0.11.9, tokenizers 0.7.0, sqlite-vec 0.1.9, docx 0.13.3, pg 1.7.0, sequel 5.110.0)
- https://github.com/ankane/informers (+ README, CHANGELOG, lib/informers/env.rb)
- https://huggingface.co/intfloat/multilingual-e5-small, https://huggingface.co/BAAI/bge-m3, https://huggingface.co/Xenova/multilingual-e5-small, /Xenova/multilingual-e5-base, /Xenova/bge-m3 — model cards and ONNX trees
- https://github.com/huggingface/text-embeddings-inference ; https://docs.ollama.com/capabilities/embeddings
- https://github.com/pgvector/pgvector ; https://github.com/pgvector/pgvector-ruby ; https://github.com/ankane/neighbor ; https://github.com/asg017/sqlite-vec
- https://hub.docker.com/v2/repositories/pgvector/pgvector/tags and /library/ruby/tags — arch lists
- https://github.com/sinatra/sinatra (README streaming, CHANGELOG 4.2.1)
- https://www.ruby-lang.org/en/downloads/releases/
- https://packages.debian.org/trixie/libreoffice-writer-nogui, libreoffice-core-nogui, fonts-noto-core — package sizes
