# NUSAskify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Execution method (decided by the user, do not ask): subagent-driven-development.**

**Goal:** Turn the existing Ruby RAG demo into the multi-tenant, versioned NUSAskify submission (tenant/version/validity data model, semantic chunking, filtered search with `min_score`, JSON `/api/*` with Swagger docs, tenant-aware chat UI, TC1-TC8 evidence, README report).

**Architecture:** Extend the shared core in place (spec approach A). `documents` gain tenant/title/version/validity/path, `chunks` get ids, `query_logs` is new; every search filters tenant, selected documents, status and validity inside the SQL before `LIMIT k`. `Rag::Ask` gains tenant/document scope, `min_score` and query logging; `/api/*` (a Sinatra extension in `src/web/api.rb`), the chat page and `scripts/*` all go through the same store, ingest and ask. Ingest is split into `prepare` (validate, hash, create the `processing` row, so the API can return an id) and `run` (extract, restructure, chunk, embed, finish).

**Tech Stack:** Ruby 3.4, Sinatra 4.2, Puma, Postgres + pgvector (`pg`, `pgvector` gems), `informers` (`Xenova/multilingual-e5-small`, 384 dims), DeepSeek via the company gateway, minitest, Docker Compose, Swagger UI from a CDN.

**Spec:** `docs/superpowers/specs/2026-11-17-nusaskify-design.md` (read it first; it holds the TC1-TC8 table and the user's decisions).

## Global Constraints

- No new gems. Swagger UI loads from a CDN at a pinned version (e.g. `swagger-ui-dist@5.17.14`).
- New settings follow `Rag.load_settings` (validated at load, error names `config/<file>: <key>`); tenants come from `config/tenants.yaml` (`tenants: [nus, acme]`, `default: nus`).
- Source is mounted read-only in Docker; only `data/raw/` and the model cache are writable. Uploads go to `data/raw/uploads/<tenant>/<uuid>-<filename>`; `scripts/ingest` never scans `uploads/`.
- API is JSON and English, error shape `{error: "..."}`; the web UI stays Vietnamese. All `/api/*` read `X-Tenant-Id`: missing or unknown -> 400 (default tenant is NOT applied on `/api/*`). The web `/ask` applies the default tenant when the header is absent; unknown -> 400.
- Existing host check (localhost only), origin check, 30 MB upload cap and 64 KB ask-body cap apply to `/api/*`; Swagger UI calls from the same origin must pass the origin check.
- Score = `1 - cosine distance` (pgvector `<=>`), reported to 3 decimals. Below `min_score` (or no hit) -> no LLM call; API `status: "not_enough_information"`, web shows `Không tìm thấy thông tin này trong tài liệu.`
- Metadata required on every ingest path: `tenant_id` (in config), `title`, `version` (positive integer), `valid_from`, `valid_to` (ISO dates, `valid_from <= valid_to`). Missing or invalid -> nothing stored (422 on web/API).
- Semantic chunking is the default unconditionally (`chunking: semantic`); `structure` stays for comparison. If it changes README demo answers or `check_retrieval` results, update the README to match; never fall back to `structure` to preserve old answers.
- "Same document" = same `(tenant_id, title)`. When a version finishes ingesting, lower `done` versions of that pair become `expired`; deleting a version never revives an older one.
- Existing demo flow keeps working in tenant `nus` with all documents checked. Existing tests keep passing; they change only where identity moves from filename to id, where a signature gains `tenant_id:`, or where semantic chunking is the default (each task lists what changes and why).
- Migration style (planner's call): no `ALTER`. `migrate!` raises a clear error on the old schema; the user runs `docker compose down -v` once (README documents it). The test database is dropped and recreated once per test process.
- Run tests with `docker compose run --rm app scripts/test` (all) or `docker compose run --rm app scripts/test tests/<file>_test.rb` (one file; `scripts/test` treats every argument as a file, so there is no `-n`). Commands needing the repo writable use `docker run --rm -v "$PWD:/app" -w /app app <cmd>` (see README section 5).
- Every commit message ends with the line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

Input classes the spec implies but its text does not exercise; each has a test in the task that owns the code.

1. `document_ids` that are empty, unknown, or belong to another tenant: empty means "all of the tenant's documents" (API/CLI) but a foreign or nonexistent id must return nothing, never fall back to "all"; the chat page must refuse to send when every box is unchecked instead of sending `[]` (tests in Tasks 2, 7, 8).
2. Validity edges and version ordering: a document is valid on `valid_from` and on `valid_to` inclusive, not the day before/after; versions compare as integers (v10 expires v2); same title in two tenants never expire each other (Task 2).
3. Deleting a document must never delete a shared sample under `data/raw/` or a file outside `data/raw/uploads/`; deleting a document while its ingest job is queued must not crash the worker (Tasks 3, 6, 7).
4. `X-Tenant-Id` variants (`NUS`, ` nus`, empty, repeated) are rejected, not normalised; bad `top_k` (0, negative, 1000, string), non-integer `document_ids`, a non-object body and a body over 64 KB give 400/413 JSON, not a 500 (Task 7).
5. Semantic chunker on degenerate pages: empty or whitespace-only page, a single sentence, a page that is one table, a heading-only page, one 5 000-character line without punctuation, and all-identical sentences (Task 4).

Also pinned: a failing `query_logs` insert must not fail the answer (Task 5).

---

### Task 1: Tenants config, new settings, struct fields

**Files:**
- Create: `config/tenants.yaml`
- Modify: `config/retriever.yaml`, `src/rag.rb`
- Test: `tests/settings_test.rb`

**Interfaces:**
- Produces: `Rag.load_settings` accepts schema type `:string_list` (non-empty Array of non-empty Strings; error text `must be a list of strings`). `Rag.load_tenants(path) -> Hash` (`"tenants"`, `"default"`; raises `Rag::Error` `config/tenants.yaml: default must be one of tenants`). Constants `Rag::TENANTS` (frozen Array<String>), `Rag::DEFAULT_TENANT`, `Rag::CHUNKING` ("semantic" or "structure", else `Rag::Error`), `Rag::MIN_SCORE` (Float), `Rag::SEMANTIC_PERCENTILE` (Integer 1..99), `Rag::SEMANTIC_FLOOR` (Float), `Rag::SEMANTIC_MIN_UNITS` (Integer). New retriever keys: `chunking: semantic`, `min_score: 0.0` (placeholder, calibrated in Task 10), `semantic_breakpoint_percentile: 25`, `semantic_floor: 0.85`, `semantic_min_units: 5`.
- Structs (all new fields appended, so existing positional/keyword construction keeps working): `Doc` += `tenant_id, title, version, valid_from, valid_to, path` plus `current?(on = Date.today)` (status `"done"` and `valid_from <= on <= valid_to`); `Hit` += `chunk_id, document_id, title, version` plus `score` (`1.0 - distance`); `Chunk` += `id`; `Source = Struct.new(:n, :filename, :page, :quote, :chunk_id, :document_id, :title, :version)`; `Answer` += `hits` plus `status` (`found ? "answered" : "not_enough_information"`). Add `require "date"`.

- [ ] **Step 1: Write failing tests** in `tests/settings_test.rb`: (a) extend `test_yaml_settings_give_the_documented_constants` area with a new test asserting `Rag::TENANTS == ["nus", "acme"]`, `DEFAULT_TENANT == "nus"`, `CHUNKING == "semantic"`, `SEMANTIC_PERCENTILE == 25`; (b) `test_string_list_type` using the existing `load_yaml` helper: `"l: [a, b]"` ok, `"l: []"`, `"l: [a, 1]"`, `"l: x"` each raise containing `l must be a list of strings`; (c) `test_load_tenants_rejects_default_outside_list` (`tenants: [a]`, `default: b` raises, message contains `default must be one of tenants`); (d) `test_doc_current_on_is_inclusive` (`Doc.new(status: "done", valid_from: d1, valid_to: d2)`: true on d1 and on d2, false the day before/after, false when status `"expired"`); (e) `test_hit_score_is_one_minus_distance` (`Hit.new(distance: 0.25).score == 0.75`); (f) `test_answer_status` (found true -> `"answered"`, false -> `"not_enough_information"`).
- [ ] **Step 2: Run** `docker compose run --rm app scripts/test tests/settings_test.rb`. Expected: FAIL (`TENANTS` undefined, etc.).
- [ ] **Step 3: Implement** `:string_list` in `load_settings`, `Rag.load_tenants`, the constants (validate `chunking` and percentile range with `Rag::Error` naming `config/retriever.yaml`), the two YAML files, and the struct changes in `src/rag.rb`.
- [ ] **Step 4: Run** `docker compose run --rm app scripts/test`. Expected: all pass. No existing test changes in this task.
- [ ] **Step 5: Commit** `git add config src/rag.rb tests/settings_test.rb && git commit -m "feat: tenants config, chunking/min_score settings, struct fields"`

---

### Task 2: Schema and store (tenant, version, validity, chunk ids, query_logs, filtered search)

**Files:**
- Modify: `src/vectordb/store.rb`, `src/retrieval/retriever.rb`, `src/ingestion/ingest.rb` (temporary shim), `src/web/app.rb` (2-line shim), `evaluation/check_retrieval` (tenant arg)
- Modify tests/support: `store_contract.rb`, `fake_store.rb`, `pg_test_db.rb`, `fakes.rb` (add `TestMeta`)
- Test: `tests/support/store_contract.rb` (runs for `PgStoreTest` and `FakeStoreTest`), `tests/pg_store_test.rb`

**Interfaces:**
- Produces (Store and FakeStore, identical contract):
  - `start_document(tenant_id:, title:, version:, valid_from:, valid_to:, filename:, path:, sha256:) -> Integer` (replaces any row with the same `(tenant_id, title, version)`, status `processing`)
  - `find_document(tenant_id:, title:, version:) -> Doc | nil`
  - `document(id, tenant_id: nil) -> Doc | nil` (with `tenant_id`, another tenant's id gives nil)
  - `finish_document(id, pages:, chunks:)` (one transaction: pages, chunks, status `done`, then expiry: other `done` versions of the same `(tenant_id, title)` with a lower integer version become `expired` with `valid_to = LEAST(valid_to, new.valid_from)`; if a higher `done` version already exists the document itself becomes `expired` and dates stay)
  - `fail_document(id, message)` (no-op on missing id), `documents(tenant_id: nil) -> [Doc]` ordered `title, version DESC, id`
  - `pages(document_id) -> [Page]`, `chunks(document_id) -> [Chunk]` (with `id`, `page`, `position`, `text`; `embedding` nil; ordered by `chunk_index, id`)
  - `delete_document(id, tenant_id:) -> Doc | nil` (cascades; other tenant: nil and nothing deleted)
  - `search(embedding, k, tenant_id:, document_ids: [], on: Date.today) -> [Hit]` (`tenant_id:` is required; SQL `WHERE d.tenant_id = $ AND d.status = 'done' AND $on::date BETWEEN d.valid_from AND d.valid_to AND (cardinality($ids) = 0 OR d.id = ANY($ids))` then `ORDER BY distance LIMIT k`; no ANN index on purpose, so the filter is applied before top-k)
  - `log_query(tenant_id:, question:, standalone:, document_ids:, retrieved_chunk_ids:, scores:, status:, answer:, cited_chunk_ids:, source:) -> nil`, `query_logs(limit: 100) -> [Hash]` newest first
- `Retriever#call(question, tenant_id: Rag::DEFAULT_TENANT, document_ids: [], k: nil) -> [Hit]`.
- `TestMeta.attrs(filename, **over) -> Hash` in `tests/support/fakes.rb`: `{tenant_id: "nus", title: filename, version: 1, valid_from: Date.new(2000,1,1), valid_to: Date.new(2999,12,31), filename:, path: "/x/#{filename}", sha256: "h"}` merged with `over`; tests call `store.start_document(**TestMeta.attrs("a.pdf"))`. Also `by_name(store, filename) -> Doc | nil` helper.
- Pg notes for the implementer: schema as in the spec (`UNIQUE (tenant_id, title, version)`, index on `(tenant_id, status)`, `chunks.id serial`, column `chunk_index` stays exposed as `Chunk#position`, index on `chunks(document_id)`); dates come back as `Date`; pass dates as ISO strings and `integer[]`/`real[]` as `"{1,2}"` literals built from `Integer(...)`/`Float(...)` values.
- Temporary shims, replaced in Tasks 3 and 6 (mark each with a `# TEMP` comment): `Ingest#ingest_file` derives metadata `{tenant DEFAULT_TENANT, title = file stem, version 1, valid 1970-01-01..9999-12-31, path}` and calls the new store API; `Web` route `/documents/*` finds the document by filename in `store.documents` then `pages(doc.id)`; `check_retrieval` passes `tenant_id: Rag::DEFAULT_TENANT`.

- [ ] **Step 1: Rewrite `store_contract.rb` tests first.** Existing tests change only mechanically: every `start_document(filename:, sha256:)` becomes `start_document(**TestMeta.attrs(name))`, `find_document("a.pdf")` becomes `by_name(store, "a.pdf")`, `pages("a.pdf")` becomes `pages(id)`, `search(v, k)` gets `tenant_id: "nus"`, and `test_documents_ordered_by_filename` becomes `test_documents_ordered_by_title_then_version_desc`. Add: `test_metadata_roundtrips_with_date_objects`; `test_find_document_by_triple`; `test_same_triple_replaces_other_version_coexists`; `test_search_filters_tenant` (same vectors in `nus` and `acme`, each tenant sees only its own); `test_search_document_ids_filter` (listed ids only; an id of the other tenant and a nonexistent id return `[]`; `[]` means all of the tenant); `test_search_validity_is_inclusive` (`on:` equal to `valid_from` and to `valid_to` hits, day before/after does not); `test_search_excludes_expired_and_processing_and_error`; `test_search_hit_has_ids_title_version_and_score` (`chunk_id`, `document_id`, `title`, `version` set, `score` 1.0 for identical vector); `test_finish_expires_lower_versions` (v1 done, v2 finishes: v1 `expired`, `valid_to` is `LEAST` of old `valid_to` and v2 `valid_from`; v1 chunks still returned by `chunks(v1_id)`); `test_versions_compare_as_integers` (v2 then v10 expires v2); `test_lower_version_finishing_after_higher_is_expired_itself`; `test_other_tenant_same_title_not_expired`; `test_delete_does_not_revive_older_version`; `test_delete_document_returns_doc_cascades_and_respects_tenant`; `test_document_lookup_by_id_scoped_by_tenant`; `test_chunks_returns_ids_in_order`; `test_log_query_roundtrip` (arrays and nil `standalone`). In `tests/pg_store_test.rb`: update `test_recovers_after_connection_is_terminated`; add `test_migrate_refuses_old_schema` (in `rag_test` drop all tables, create `documents(id serial primary key, filename text)`, expect `Rag::Error` mentioning `docker compose down -v`, then clean up).
- [ ] **Step 2: Run** `docker compose run --rm app scripts/test tests/pg_store_test.rb tests/fake_store_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement** the Store changes and `migrate!` old-schema check (`documents` exists without `tenant_id` column -> `Rag::Error` telling the user to run `docker compose down -v`). Change `PgTestDb.url` to drop and recreate `rag_test` (`DROP DATABASE IF EXISTS rag_test WITH (FORCE)`) once per process (memoized) so an old-schema volume cannot break tests; `PgTestDb.clear!` also truncates `query_logs`.
- [ ] **Step 4: Implement** `FakeStore` with the same contract (in-memory; cosine as today; same expiry and filter rules).
- [ ] **Step 5: Implement** the shims and `Retriever` signature listed above. Mechanical test updates elsewhere (reason: identity moved from filename to id, `search` needs `tenant_id:`): `tests/ingest_test.rb` (every `@store.search(x, n)` gets `tenant_id: "nus"`; `@store.find_document(name)` -> `by_name(@store, name)`; `@store.pages(name)` -> pages of that doc id), `tests/ask_test.rb` `add()` helper and `tests/web/ask_route_test.rb` `done_store` (use `TestMeta.attrs`), `tests/web/documents_route_test.rb` `add()` helper (same).
- [ ] **Step 6: Run** `docker compose run --rm app scripts/test`. Expected: all pass (documents page and viewer tests still pass through the shim).
- [ ] **Step 7: Commit** `git add src config tests evaluation && git commit -m "feat: tenant/version/validity schema, filtered search, query_logs"`

---

### Task 3: Metadata, manifest, ingest prepare/run, version expiry end to end

**Files:**
- Create: `src/ingestion/metadata.rb`, `src/ingestion/manifest.rb`, `tests/metadata_test.rb`, `tests/manifest_test.rb`
- Modify: `src/ingestion/ingest.rb`, `scripts/ingest`, `data/samples/manifest.yml` (metadata on the 4 existing entries; dates as quoted strings)
- Test: `tests/ingest_test.rb`

**Interfaces:**
- Produces: `Rag::Meta = Struct.new(:tenant_id, :title, :version, :valid_from, :valid_to, keyword_init: true)`; `Rag::Meta.parse(hash) -> Meta` (symbol keys; `version` Integer or digit String; dates `Date` or `YYYY-MM-DD` String only; title squashed, 1..200 chars; tenant must be exactly in `Rag::TENANTS`); raises `Rag::Meta::Invalid < Rag::Error` with `#field` and a Vietnamese message. `Rag::Manifest.load(path = DEFAULT_PATH) -> Hash{nfc basename of "out" => Meta}` (every entry needs `tenant, title, version, valid_from, valid_to`, else `Invalid` naming the entry).
- `Ingest.new(llm:, embedder:, store:, extractor: Rag::Extract, chunking: Rag::CHUNKING)`.
  - `prepare(path, meta, filename: nil) -> Prepared` where `Prepared = Struct.new(:id, :skipped, :filename)`: checks extension (`Rag::Error "Chỉ nhận file .pdf và .docx."`), hashes the file, `find_document` by triple; same sha256 and `done` -> `Prepared(existing.id, true, filename)`; else `start_document` (`filename` defaults to NFC basename).
  - `run(id, path) -> String | nil` (failure message): extract, restructure, chunk, embed, `finish_document`; records `fail_document` on error; never raises for a per-file failure, including a document deleted meanwhile.
  - `call(path, metadata) -> Report` (`metadata` is a `Meta` applied to a single file, or a Hash `basename => Meta`); a file without metadata is listed in `Report#no_metadata` and not ingested. `Report` gains `no_metadata`; `summary` adds `Bỏ qua (thiếu metadata): a.pdf, b.pdf`; `failed?` ignores `no_metadata` (script exit code unchanged).

- [ ] **Step 1: Write failing tests.** `tests/metadata_test.rb`: valid parse (`"3"` -> 3, ISO strings -> `Date`); rejects with the right `#field` for: blank/missing title, 201-char title, tenant `"NUS"`, `" nus"`, `"zzz"`, version `0`, `-1`, `"1.5"`, `"abc"`, `nil`, date `"2026-13-01"`, `"2026-1-1"`, `"20260101"`, `nil`, and `valid_from > valid_to`; equal dates accepted. `tests/manifest_test.rb`: temp YAML with two entries loads keyed by basename; an entry missing `version` raises `Invalid`; the real `data/samples/manifest.yml` loads. `tests/ingest_test.rb` (reason: `call` now needs metadata and `Report` gained a field): helper `meta(**o)` and `metas(*names)`; every `.call(path)` becomes `.call(path, meta)` (single file) or `.call(@dir, metas(...))`; `test_single_file_path_and_unsupported_extension_path` passes a `Meta` for `c.txt`. Add: `test_prepare_then_run_stores_document_with_metadata`; `test_prepare_skips_same_sha_done_and_returns_existing_id`; `test_prepare_same_triple_new_sha_replaces`; `test_prepare_rejects_bad_extension_without_creating_a_row`; `test_file_without_metadata_is_listed_and_not_ingested` (summary contains `Bỏ qua (thiếu metadata): x.pdf`, `failed?` false); `test_new_version_expires_old_version_end_to_end` (v1 then v2 different content: v1 status `expired`, search returns only v2 text); `test_older_version_ingested_after_newer_is_expired`; `test_run_on_deleted_document_does_not_raise` (`delete_document` between prepare and run: `run` returns a message, store unchanged); `test_run_failure_returns_message_and_marks_error`.
- [ ] **Step 2: Run** `docker compose run --rm app scripts/test tests/metadata_test.rb tests/manifest_test.rb tests/ingest_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement** `Meta`, `Manifest`, and the `Ingest` restructure (remove the Task 2 shim; keep the page processing body of `process` unchanged apart from taking `chunking:`; chunker switch itself is Task 4, so `Chunker.split` still used here). Per-file `rescue StandardError` behaviour of `call` stays: message hidden for non-`Rag::Error`, class logged to stderr.
- [ ] **Step 4: Update `scripts/ingest`:** load `Rag::Manifest.load`, call `sys.ingest.call(p, manifest)` for each path; add metadata (`tenant: nus`, `title`, `version: 1`, `valid_from: "2026-01-01"`, `valid_to: "2099-12-31"`; titles `Quy chế nghỉ phép`, `Quy định làm việc từ xa`, `Travel expense policy`, `Chính sách hoàn tiền`) to the 4 manifest entries (the leave policy becomes version 2 in Task 9; keep 1 here).
- [ ] **Step 5: Run** `docker compose run --rm app scripts/test`. Expected: all pass. (`config.ru`'s worker job still calls the old `ingest.call(path)`; uploads through the web are broken until Task 6 and covered there. Do not paper over it.)
- [ ] **Step 6: Commit** `git add src scripts data/samples/manifest.yml tests && git commit -m "feat: required metadata, manifest, ingest prepare/run, version expiry"`

---

### Task 4: SemanticChunker and the chunking switch

**Files:**
- Create: `src/chunking/semantic_chunker.rb`, `tests/semantic_chunker_test.rb`
- Modify: `src/ingestion/ingest.rb`
- Test: `tests/ingest_test.rb`

**Interfaces:**
- Consumes: `Rag::SEMANTIC_PERCENTILE`, `SEMANTIC_FLOOR`, `SEMANTIC_MIN_UNITS`, `MAX_CHUNK_CHARS`, `Rag::Chunker.pieces(text, max)` (public, reused for oversize units), `Rag::Chunker.split` (structure).
- Produces: `Rag::SemanticChunker.units(text) -> [String]` and `Rag::SemanticChunker.split(text, embed:, max_chars: MAX_CHUNK_CHARS, percentile: SEMANTIC_PERCENTILE, floor: SEMANTIC_FLOOR, min_units: SEMANTIC_MIN_UNITS) -> [String]`; `embed` is any callable `Array<String> -> Array<Array<Float>>`, called once per `split` with all units. `Ingest` picks the splitter per `chunking:` (`"semantic"` -> `SemanticChunker.split(page_text, embed: ->(t) { @embedder.embed_passages(t) })`, `"structure"` -> `Chunker.split`).

- [ ] **Step 1: Write failing tests** in `tests/semantic_chunker_test.rb` with a scripted `embed` (one-hot per topic keyword, so similarity is exactly 1 inside a topic and 0 across): (a) two topics of three sentences each split into two chunks at the topic change; (b) a 25th-percentile threshold cuts at the lowest neighbour similarities only (script similarities so exactly one of four gaps is lowest); (c) fewer than `min_units` units uses `floor` instead of the percentile (same input, `floor: 0.5` -> one chunk, `floor: 1.1` -> every unit its own chunk); (d) a chunk never exceeds `max_chars` even when all sentences are similar; (e) a markdown table stays one unit (one chunk contains all its rows), and a table longer than `max_chars` is split by rows; (f) a heading attaches to the unit that follows it (heading is never the last line of a chunk unless it is the last unit); (g) `embed` called exactly once per page; (h) no content lost: `Text.squash(chunks.join(" "))` contains every unit's squashed text. Degenerate pages (Review Focus 5): empty and whitespace-only -> `[]`; one sentence -> that sentence; heading-only page -> one chunk with the heading; one 5 000-char line with no punctuation -> several chunks each `<= max_chars` (via `Chunker.pieces`); identical sentences -> one chunk below `max_chars`. In `tests/ingest_test.rb`: the helper `ingest` passes `chunking: "structure"` by default (reason: two existing tests assert `@embedder.inputs.size == 1` and `Rag::Chunker.split` output; the default is now semantic), plus `test_semantic_chunking_is_the_default_and_embeds_units_then_chunks` (build `Rag::Ingest` without `chunking:`; `@embedder.inputs.size == 2`) and `test_chunking_structure_matches_chunker_split`.
- [ ] **Step 2: Run** `docker compose run --rm app scripts/test tests/semantic_chunker_test.rb tests/ingest_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement `units`** per the spec: split into sentences at `.`/`!`/`?` followed by whitespace and at line breaks; consecutive `|` lines form one table unit; `#` headings are prefixed onto the next unit; NFC-normalise.
- [ ] **Step 4: Implement `split`:** embed all units once; cosine between neighbours computed with explicit norms (do not assume unit-length vectors); breakpoint = `percentile`-th percentile of the page's neighbour similarities when there are at least `min_units - 1` similarities, else `floor`; start a new chunk when similarity `<` breakpoint or when adding the unit would exceed `max_chars`; oversize single units go through `Chunker.pieces`; join units inside a chunk with `"\n"`, table/heading units with `"\n\n"` as `Chunker::SEP` does. Wire `chunking:` into `Ingest`.
- [ ] **Step 5: Run** `docker compose run --rm app scripts/test`. Expected: all pass.
- [ ] **Step 6: Commit** `git add src tests && git commit -m "feat: semantic chunker as default chunking"`

---

### Task 5: Ask and Retriever (scope, min_score, Hit fields, query log)

**Files:**
- Modify: `src/generation/ask.rb`, `src/rag.rb` (`Rag::System` gains `retriever`), `src/config.rb`, `scripts/ask`
- Test: `tests/ask_test.rb`

**Interfaces:**
- Consumes: `Store#search`, `Store#log_query`, `Hit#score`, `Source`, `Answer#hits`.
- Produces: `Ask.new(llm:, embedder:, store:, k: Rag::TOP_K, min_score: Rag::MIN_SCORE)`; `Ask#call(question, history = [], tenant_id: Rag::DEFAULT_TENANT, document_ids: [], source: "cli", &on_delta) -> Answer` where `Answer#hits` is always the retrieved `Hit` list (also when not found) and `Source` carries `chunk_id, document_id, title, version, filename, page, quote`. `Rag.build` sets `System#retriever = Retriever.new(embedder:, store:, k: TOP_K)`. Every non-blank ask writes one `query_logs` row (`tenant_id`, `question`, `standalone`, `document_ids`, retrieved ids/scores, `status`, `answer`, `cited_chunk_ids`, `source`); a logging exception is rescued and warned (`query log failed: <class>`), never raised. The prompt text is unchanged (`file=<filename> page=<n>`).

- [ ] **Step 1: Write failing tests** in `tests/ask_test.rb`. Existing-test changes (reason: `Source` has more fields; `min_score` must not block the bag-of-words `FakeEmbedder`): the `ask` helper builds `Ask` with `min_score: -1.0`; the `src(quote)` helper builds a `Source` with the ids the `FakeStore` assigned (`chunk_id`, `document_id`, `title`, `version`) and `filename`. New tests: `test_below_min_score_returns_not_enough_without_calling_llm` (identical text scores ~1.0; `min_score: 1.1` -> `found` false, `@llm.calls` empty, `hits` still populated, status `not_enough_information`); `test_score_equal_to_min_score_still_goes_to_the_llm`; `test_no_hits_returns_not_enough_without_llm`; `test_tenant_scope_other_tenant_chunk_never_reaches_prompt` (doc in `acme`, ask as `nus`: no LLM call); `test_document_ids_scope_excludes_unselected_document_from_prompt`; `test_foreign_or_unknown_document_id_returns_not_enough` (Review Focus 1); `test_citation_carries_chunk_id_of_the_hit`; `test_every_ask_writes_one_query_log_row` (fields as listed, `source` passes through, row also written for not-enough and for an LLM `NOT_FOUND`); `test_blank_question_writes_no_log`; `test_log_failure_does_not_fail_the_answer` (store whose `log_query` raises: answer returned, stderr contains `query log failed`).
- [ ] **Step 2: Run** `docker compose run --rm app scripts/test tests/ask_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement** in `Ask`: pass `tenant_id`/`document_ids` to the retriever; after retrieval, `hits.empty? || hits.first.score < @min_score` -> `Answer.new("", false, [], standalone, hits)` before any LLM call; build `Source` from the hit; wrap the existing body so logging happens once in a `ensure`-free `begin/rescue` after the answer exists. `scripts/ask` prints `[n] <title> v<version> · trang <p>`; update `Rag.build`.
- [ ] **Step 4: Run** `docker compose run --rm app scripts/test`. Expected: all pass.
- [ ] **Step 5: Commit** `git add src scripts tests && git commit -m "feat: scoped retrieval, min_score gate, citations with chunk ids, query log"`

---

### Task 6: Upload pipeline and documents page (metadata form, delete, viewer by id)

**Files:**
- Modify: `src/ingestion/upload.rb`, `src/web/worker.rb`, `src/web/app.rb`, `src/web/views/documents.erb`, `src/web/views/document.erb`, `config.ru`, `tests/support/fakes.rb` (move `FakeWorker` here)
- Test: `tests/upload_test.rb`, `tests/web/worker_test.rb`, `tests/web/documents_route_test.rb`

**Interfaces:**
- Consumes: `Ingest#prepare/run`, `Meta.parse`, `Store#documents/document/pages/delete_document`.
- Produces: `Upload.save(filename:, io:, dir:, max_bytes:, unique: false)` (`unique: true` writes `<uuid>-<sanitized name>`); `Upload.remove(path, root:) -> Boolean` (deletes only a regular file whose realpath is inside `root`, else false). `Worker#enqueue(key, *args)`, job block called as `job.call(key, *args)`, `pending -> [key]` (opaque keys; document ids from now on). Web helpers (in `Web`, reused by Task 7): `accept_upload(tenant_id, fields, file) -> Ingest::Prepared` (parse `Meta`, save under `documents_dir/uploads/<tenant>/` with `unique: true`, `ingest.prepare(path, meta, filename: sanitized)`, remove the saved file when skipped or when prepare raises, `worker.enqueue(id, path)` unless skipped; raises `Rag::Meta::Invalid` / `Rag::Upload::Rejected`) and `delete_document!(id, tenant_id) -> Boolean` (store delete, then `Upload.remove(doc.path, root: documents_dir/uploads)`; never touches `data/raw/*.pdf`). New settings `:ingest`. Routes: `GET /documents?tenant=`, `POST /documents` (form fields `tenant_id`, `title`, `version`, `valid_from`, `valid_to`, `file`), `POST /documents/:id/delete` (field `tenant_id`), `GET /documents/:id` (digits only, `?page=&q=` as today). `config.ru`: `Worker.new { |id, path| sys.ingest.run(id, path) }`, `Web.set :ingest, sys.ingest`.

- [ ] **Step 1: Write failing tests.** `upload_test.rb`: `test_unique_prefixes_uuid_and_keeps_sanitized_name`; `test_two_unique_saves_of_the_same_name_do_not_collide`; `test_remove_deletes_inside_root_only` (a path outside `root`, a symlink pointing outside, a directory, a missing file all return false and delete nothing). `worker_test.rb` (reason: keys are no longer basenames): `test_jobs_run_one_at_a_time_in_order` and `test_failing_job_does_not_kill_worker` use `enqueue(id, path)`; `test_pending_lists_queued_and_running_keys_then_empties` asserts `[1, 2]`; `test_non_rag_error_logs_class_only` unchanged in spirit. `documents_route_test.rb` rewritten where it keyed on filename (reason: identity is the id and rows gain metadata): list shows title, `v<version>`, validity range, status, pages, chunks, a delete form per row; `expired` rows visible and marked `hết hiệu lực`; `?tenant=acme` shows only acme rows; unknown tenant -> 400; processing document whose id is in `worker.pending` -> `đang xử lý`, not pending -> the existing `lỗi: bị gián đoạn...` text, no refresh; upload with full metadata -> 303, file stored at `uploads/nus/<uuid>-a.pdf`, `FakeWorker.enqueued == [[id, path]]`, store row `processing` with metadata; upload with missing/invalid metadata (title blank, version `0`, dates reversed, unknown tenant) -> 422, Vietnamese message in the page, no file left, nothing enqueued, no row; same sha256 re-upload of a `done` document -> 303, saved duplicate removed, nothing enqueued; existing size/origin/traversal/no-file tests keep their assertions with the new fields added to the helper; viewer tests use `/documents/<id>` (old filename URLs now 404; keep the escaping, collapse, highlight, invalid-page assertions); `test_delete_removes_row_and_uploaded_file`, `test_delete_never_removes_a_file_outside_uploads` (doc whose `path` is `<documents_dir>/seed.pdf` and one with a path outside the dir: files remain), `test_delete_other_tenant_is_404_and_keeps_data`.
- [ ] **Step 2: Run** the three files. Expected: FAIL.
- [ ] **Step 3: Implement** `Upload` changes and `Worker` generalisation.
- [ ] **Step 4: Implement** the `Web` helpers, routes (replace the Task 2 `/documents/*` shim), views (tenant `<select>` form on the list page; small inline script: remember the choice in `localStorage["rag.tenant"]`, and when `?tenant=` is absent and the stored tenant differs from the default, `location.replace`; upload form with the metadata inputs, title prefilled from the chosen filename, version 1, `valid_from` today; delete button using a POST form with a `confirm`), and `config.ru`. All dynamic values go through `h(...)`.
- [ ] **Step 5: Run** `docker compose run --rm app scripts/test`. Expected: all pass.
- [ ] **Step 6: Commit** `git add src config.ru tests && git commit -m "feat: metadata upload form, id-keyed worker, delete, viewer by id"`

---

### Task 7: JSON API, OpenAPI and Swagger UI

**Files:**
- Create: `src/web/api.rb` (Sinatra extension `WebApi`, registered in `app.rb`), `src/web/openapi.yaml`, `tests/web/api_test.rb`
- Modify: `src/web/app.rb` (register, `set :retriever`), `config.ru` (`Web.set :retriever, sys.retriever`)

**Interfaces:**
- Consumes: `Web#accept_upload`, `Web#delete_document!`, `Retriever`, `Ask#call(..., source: "api")`, `Store`.
- Produces routes (all JSON, `X-Tenant-Id` required, exact match against `Rag::TENANTS`, error `{error: "..."}`):
  - `POST /api/documents` multipart `file`, `title`, `version`, `valid_from`, `valid_to` -> 202 `{id, status}`; 422 `{error, field, detail}` for invalid metadata or a rejected file
  - `GET /api/documents[?current=true]` -> `{documents: [{id, title, version, filename, valid_from, valid_to, status, error, chunk_count}]}` (`current=true` keeps only `Doc#current?`)
  - `GET /api/documents/:id/chunks` -> `{chunks: [{id, chunk_index, page, text}]}`; 404 for another tenant
  - `DELETE /api/documents/:id` -> 200 `{id, deleted: true}`; 404 for another tenant
  - `POST /api/search` `{question, document_ids, top_k}` -> `{chunks: [chunk]}` with `chunk = {chunk_id, document_id, title, version, page, score (3 decimals), content}`; no LLM, no `min_score`
  - `POST /api/ask` `{question, document_ids}` -> `{status: "answered" | "not_enough_information", answer, citations: [{n, chunk_id, document_id, title, version, page, quote}], chunks}`; `answer` is `"Not enough information in the documents."` when not enough and `citations` is `[]`
  - `GET /api/openapi.yaml`, `GET /api/docs` (Swagger UI page loading the pinned CDN bundle and `/api/openapi.yaml`)
  - Shared serializer `WebApi.chunk(hit) -> Hash` (used again by Task 8). Validation: `question` non-blank String <= 2000 chars; `document_ids` optional Array of positive Integers, at most 200; `top_k` optional Integer 1..20 (default `Rag::TOP_K`). Body cap 64 KB (413), non-JSON or non-object body 400. `Rag::Error` from the LLM -> 502 `{error: "upstream error"}`; anything else -> 500 `{error: "internal error"}` with the class logged only.

- [ ] **Step 1: Write failing tests** in `tests/web/api_test.rb` using real `Ask`/`Retriever`/`Ingest` over `FakeStore`, `FakeEmbedder`, `FakeLLM`, `FakeExtractor`, `FakeWorker` (host `localhost:4567`). Tenant header: missing, empty, `NUS`, ` nus`, `nus,acme`, `zzz` -> 400 on every route (Review Focus 4). Documents: list scoped to tenant, `current=true` hides expired and out-of-window, `chunk_count` correct; chunks 404 across tenants; delete 404 across tenants keeps data, delete removes row and the uploaded file, delete of a seeded `data/raw`-style path keeps the file; POST 202 with `{id, status: "processing"}` and a `processing` row plus enqueued job, 422 for each invalid metadata case, 422 for `.txt`. Search: shape and 3-decimal scores, `top_k` honoured, `top_k` `0`, `-1`, `1000`, `"3"`, `1.5` -> 400, `document_ids` `["a"]`, `[0]`, `{}`, 201 ids -> 400, blank question 400, non-object body 400, 65 KB body 413. Mechanical TCs: TC4 (v1 expired and v2 current, search and ask return only v2 chunk ids), TC5 (acme and nus docs with same title: each header sees only its own chunk ids), TC6 (`document_ids: [A]` while asking about B: zero B chunks), TC7 (every `citations[].chunk_id` is in `chunks[].chunk_id` and `quote` is non-nil and contained in that chunk's `content` after `Rag::Text.comparable`), TC3 (`min_score` high: `status` `not_enough_information`, `FakeLLM.calls` empty, `chunks` still present), foreign `document_ids` -> `not_enough_information` or empty chunks, never all-documents (Review Focus 1); each ask writes a `query_logs` row with `source: "api"`. Docs: `/api/openapi.yaml` parses and its `paths` contain exactly the 6 spec paths with the right methods, each declaring the `X-Tenant-Id` header parameter; `/api/docs` HTML contains the pinned `swagger-ui-dist@` URL and `/api/openapi.yaml`; a same-origin `Origin: http://localhost:4567` POST passes, a foreign origin is 403.
- [ ] **Step 2: Run** `docker compose run --rm app scripts/test tests/web/api_test.rb`. Expected: FAIL (404s).
- [ ] **Step 3: Implement** `WebApi` (before-filter for `/api/*` tenant check, JSON helpers, routes above) and register it in `Web`; wire `:retriever`.
- [ ] **Step 4: Write `src/web/openapi.yaml`** by hand (OpenAPI 3.0, English, one example per request/response, header parameter `X-Tenant-Id` on every operation, the `chunk` and error schemas).
- [ ] **Step 5: Run** `docker compose run --rm app scripts/test`. Expected: all pass. Manual smoke (needs `.env`): `docker compose up -d`, `curl -s -H 'X-Tenant-Id: nus' localhost:4567/api/documents` returns JSON; `/api/docs` renders in a browser.
- [ ] **Step 6: Commit** `git add src config.ru tests && git commit -m "feat: JSON API under /api with OpenAPI and Swagger UI"`

---

### Task 8: Web `/ask` with scope and chunks, chat page UI

**Files:**
- Modify: `src/web/app.rb` (`/ask`, `/`), `src/web/views/ask.erb`, `src/web/views/layout.erb` (only CSS for the new controls)
- Test: `tests/web/ask_route_test.rb`

**Interfaces:**
- Consumes: `Ask#call(q, history, tenant_id:, document_ids:, source: "web")`, `WebApi.chunk`, `GET /api/documents?current=true`.
- Produces: `POST /ask` reads `X-Tenant-Id` (absent -> `Rag::DEFAULT_TENANT`, unknown -> 400 `Tenant không hợp lệ.`) and body `document_ids` (optional Array of positive Integers, at most 200, else 400 `Yêu cầu không hợp lệ.`). The `done` SSE event additionally carries `chunks: [WebApi.chunk(hit)]` (also when not found) and each source carries `chunk_id, document_id, title, version` next to `filename`, `page`, `quote`, `docx`. `GET /` renders `<select id="tenant">` (options from `Rag::TENANTS`, default selected), `<div id="scope">`, plus the existing hooks.

- [ ] **Step 1: Write failing tests.** `FakeAsk#call` gains the keywords (`tenant_id:`, `document_ids:`, `source:`) and records them (reason: signature). New: `test_ask_passes_tenant_header_and_document_ids_and_source_web`; `test_missing_tenant_header_uses_default`; `test_unknown_or_blank_tenant_header_is_400_and_ask_not_called`; `test_document_ids_validation` (`"1"`, `[0]`, `["a"]`, `[1.5]`, 201 ids -> 400, ask not called); `test_done_event_carries_chunks_and_source_ids` (chunk fields, `score` 3 decimals); `test_done_event_has_chunks_when_not_found`; `test_index_has_tenant_select_scope_and_chunk_hooks` (`id="tenant"` with options `nus`/`acme`, `id="scope"`). Existing `/ask` tests stay as they are.
- [ ] **Step 2: Run** `docker compose run --rm app scripts/test tests/web/ask_route_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement** the `/ask` and `/` changes.
- [ ] **Step 4: Implement the chat page JS/HTML in `ask.erb`** (no JS test runner exists; the behaviours below are the checklist for the Manual verification):
  - Tenant `<select id="tenant">` above the chat; value stored in `localStorage["rag.tenant"]`; changing it aborts any stream, starts a new chat and reloads the scope. Saved chats get a `tenant` field (missing -> default tenant); the sidebar lists only the current tenant's chats, so one conversation never mixes tenants.
  - `#scope` lists `GET /api/documents?current=true` (header `X-Tenant-Id`) as checkboxes `title (vN)`, all checked; a response arriving after a tenant switch is discarded; empty list shows a Vietnamese note.
  - Submit sends header `X-Tenant-Id` and `document_ids` of the checked boxes; with none checked it sends nothing and shows `Chọn ít nhất một tài liệu.` (Review Focus 1).
  - Each answered or not-found turn gets `<details>` `Đoạn tìm được (N)` listing `[i] title vN · tr.P · 0.xxx` and the chunk content; all text set with `textContent`. Chunks are kept in the saved turn (existing quota handling stays).
  - Sources show `title vN` and link `/documents/<document_id>?page=N&q=...` (same `#hit` / `#page-N` anchor logic).
  - `loadChats` validation accepts old saved chats without `tenant` or `chunks`.
- [ ] **Step 5: Run** `docker compose run --rm app scripts/test`. Expected: all pass. Manual: see Done-when Manual list.
- [ ] **Step 6: Commit** `git add src tests && git commit -m "feat: tenant dropdown, document scope, chunk panel on the chat page"`

---

### Task 9: Sample data (expired leave v1, acme document) and question set

**Files:**
- Create: `data/samples/src/quy-che-nghi-phep-v1.html`, `data/samples/src/acme-quy-dinh-lam-viec-tu-xa.html`, then (generated, never hand-edited) `data/raw/quy-che-nghi-phep-v1.pdf`, `data/raw/acme-quy-dinh-lam-viec-tu-xa.docx`
- Modify: `data/samples/manifest.yml`, `evaluation/questions.yml`, `tests/samples_test.rb`

**Interfaces:**
- Manifest: leave policy `data/raw/quy-che-nghi-phep.pdf` becomes `version: 2`, `valid_from: "2026-01-01"`, `valid_to: "2099-12-31"`; new entry `quy-che-nghi-phep-v1.pdf` (`tenant: nus`, same title `Quy chế nghỉ phép`, `version: 1`, `valid_from: "2024-01-01"`, `valid_to: "2025-12-31"`, `preload: true`); new entry `acme-quy-dinh-lam-viec-tu-xa.docx` (`tenant: acme`, title `Quy định làm việc từ xa`, version 1, `valid_from: "2026-01-01"`, `valid_to: "2099-12-31"`, `lang: vi`, `preload: true`).
- Question tags in `evaluation/questions.yml` (new optional keys `tc` (list), `tenant` (default `nus`), `select` (list of file names)): carry-over question `tc: [TC1, TC2, TC4, TC7]`; `Công ty thưởng Tết...` `tc: [TC3]`; `Tiền mạng hàng tháng...` `tc: [TC6]`, `select: [travel-expense-policy.pdf]`; new `Một tuần được làm việc từ xa tối đa mấy ngày?` (`file: quy-dinh-lam-viec-tu-xa.docx`, `contains: "tối đa 2 ngày"`, `tenant: nus`, `tc: [TC5]`) and its acme twin (`file: acme-quy-dinh-lam-viec-tu-xa.docx`, `contains: "tối đa 4 ngày"`, `tenant: acme`, `tc: [TC5]`).

- [ ] **Step 1: Write failing tests** in `tests/samples_test.rb`: `test_every_manifest_entry_has_valid_metadata` (`Rag::Manifest.load` covers every `out`); `test_nus_leave_policy_has_expired_v1_and_current_v2` (same title, v1 `valid_to` before 2026-01-01, v2 window contains `Date.today`); `test_acme_document_exists_with_a_nus_namesake_title`; `test_v1_differs_from_v2_on_every_figure_the_questions_ask_about` (the carry-over `contains` phrase `tối đa 5 ngày` is present on a v2 page and absent from every v1 page; same for `16 ngày`, `3 ngày làm việc`, `9 giờ sáng`); `test_tc_tags_cover_tc1_tc3_tc4_tc5_tc6_tc7_and_tenants_are_configured`. Existing assertions keep working: the manifest now has 5 preloaded entries (still all under `data/raw/`) and 1 non-preload; update only the literal counts that assume 3 preloaded (`test_manifest_covers_spec_mix` already uses `>=`).
- [ ] **Step 2: Run** `docker compose run --rm app scripts/test tests/samples_test.rb`. Expected: FAIL.
- [ ] **Step 3: Author the two HTML sources** from the existing HTML as the style template (3 or more `page-break-before: always` pages each, `<h1>/<h2>`, at least one table). v1: copy `quy-che-nghi-phep.html`, change every figure the question set touches (carry-over `5` -> `3` days, `16 ngày` -> `14 ngày`, `3 ngày làm việc` -> `2 ngày làm việc`, `9 giờ sáng` -> `8 giờ sáng`) and any other number that would otherwise collide; header says `Phiên bản 1`, v2 header gets `Phiên bản 2`. acme: Vietnamese remote-work policy for "Công ty Acme Demo" on the same topic with different numbers (`tối đa 4 ngày` per week, internet allowance `500.000 đồng`, report a stolen laptop `trong vòng 8 giờ`, set the schedule by a different deadline); it must not contain any `probe` term of the unanswerable questions (`thưởng`, `tết`, `tháng 13`, `gym`, `fitness`, `wellness`, `membership`).
- [ ] **Step 4: Build the binaries:** `docker run --rm -v "$PWD:/app" -w /app app scripts/build_samples`. Expected: `built ... (N pages)` for every manifest entry, exit 0. Note: rebuilding changes the sha256 of existing binaries; commit only the two new binaries and revert any rebuilt old ones with `git checkout data/raw/quy-che-nghi-phep.pdf data/raw/quy-dinh-lam-viec-tu-xa.docx data/raw/travel-expense-policy.pdf data/samples/upload-demo` before committing, so existing ingested hashes stay stable.
- [ ] **Step 5: Run** `docker compose run --rm app scripts/test`. Expected: all pass (includes the LibreOffice-based sample tests).
- [ ] **Step 6: Commit** `git add data evaluation tests && git commit -m "feat: sample data for expired version and second tenant, TC-tagged questions"`

---

### Task 10: Evaluation scripts (check_retrieval scores, min_score calibration, run_tc, compare_chunking)

**Files:**
- Modify: `evaluation/check_retrieval`, `config/retriever.yaml` (`min_score` value)
- Create: `evaluation/run_tc`, `evaluation/compare_chunking`

**Interfaces:**
- `check_retrieval`: scopes each search by `q["tenant"] || Rag::DEFAULT_TENANT`, prints each question's top-1 score, and ends with `answerable top-1 min=<x> | unanswerable top-1 max=<y> | in top 6: N/M` (exit rule unchanged: 1 below 80%). This is the calibration data for `min_score`.
- `run_tc`: plain Ruby (`net/http`, `json`, `yaml`), base URL from `BASE` (default `http://app:4567`) with an explicit `Host: localhost:4567` header (the app's host check only permits localhost names); needs the web container up. Prints a table `TC | PASS/FAIL | detail` for TC1-TC7 using the tags in `questions.yml` and checks listed in the spec (TC1 right chunk in top 6 and answer cites it; TC2 prints the top 3 chunks with scores; TC3 `not_enough_information`; TC4 no chunk of the expired document (found through `GET /api/documents`); TC5 acme header returns only acme document ids and nus header none of them; TC6 only the selected document id; TC7 every `citations[].chunk_id` in `chunks` with a verified `quote`); a final line `TC8 manual (see README)`. Exit 1 on any FAIL.
- `compare_chunking`: reads the default tenant's current documents and their stored pages (markdown, or raw text when `fallback`), chunks them in memory with `Chunker.split` and `SemanticChunker.split` (no DB writes), embeds, ranks chunks per answerable `nus` question by cosine, and prints per strategy: chunk count, average chars, hit@6 and the rank of the right chunk per question, as a markdown table.

- [ ] **Step 1: Bring up data** (live, paid DeepSeek calls, one per page: 18 pages or more): `docker compose down -v && docker compose run --rm app scripts/ingest && docker compose up -d`. Expected: `OK:` line listing the 5 preload documents; the two stray PDFs in `data/raw/` appear under `Bỏ qua (thiếu metadata):`; exit 0.
- [ ] **Step 2: Implement** the `check_retrieval` changes and run `docker compose run --rm app evaluation/check_retrieval`. Expected: ends with the summary line; exit 0 (at least 80%). Pick `min_score` between `unanswerable top-1 max` and `answerable top-1 min` (the midpoint; if the ranges overlap, choose the value that keeps every answerable question and say so), set it in `config/retriever.yaml` with a comment, and re-run until no answerable question falls below it.
- [ ] **Step 3: Implement `run_tc`** and run `docker compose run --rm app evaluation/run_tc`. Expected: TC1-TC7 `PASS`, exit 0. A FAIL here is a real bug (do not edit the check to pass; diagnose retrieval vs generation and fix the code or data in the owning task's files).
- [ ] **Step 4: Implement `compare_chunking`** and run `docker compose run --rm app evaluation/compare_chunking`. Expected: a table with both strategies and no exception. If semantic chunking is worse on hit@6, tune `semantic_breakpoint_percentile` / `semantic_floor` once in `config/retriever.yaml`, re-ingest (`docker compose down -v` again) and re-run; record the final values.
- [ ] **Step 5: Run** `docker compose run --rm app scripts/test`. Expected: all pass.
- [ ] **Step 6: Commit** `git add evaluation config && git commit -m "feat: run_tc, compare_chunking, min_score calibration"`

---

### Task 11: README report (Vietnamese)

**Files:**
- Modify: `README.md`

All numbers and outputs in this task come from commands run in this task or Task 10, on the freshly ingested data; none may be invented or copied from the old README.

- [ ] **Step 1: Collect evidence** (data from Task 10 step 1 still loaded; re-run `docker compose down -v && docker compose run --rm app scripts/ingest && docker compose up -d` if not): `docker compose run --rm app evaluation/check_retrieval` (record `N/M in top 6`, the two score extremes, and how `min_score` was chosen), `docker compose run --rm app evaluation/compare_chunking` (record the table), `docker compose run --rm app evaluation/run_tc` (record the TC1-TC7 table), and for TC2 `curl -s -X POST localhost:4567/api/search -H 'X-Tenant-Id: nus' -H 'content-type: application/json' -d '{"question":"<TC1 question>","document_ids":[],"top_k":3}'` (record top 3 with scores and the word mismatch that semantic search bridges).
- [ ] **Step 2: Find TC8** with `/api/search`: try questions where the most similar chunk is not the answer (candidates: a figure for another tier or section such as `What is the hotel limit per night in a Tier 2 city?`, a negation or exception clause, a near-duplicate topic across documents); record the first real failure with the `/api/search` output and diagnose it as a retrieval failure (right chunk absent or lower ranked) versus a generation failure (right chunk present, wrong answer). If the corpus yields none, say so and show the closest near-miss rather than inventing one.
- [ ] **Step 3: Verify the demo script** (section 3) against the new data: ask each demo question through the chat page or `scripts/ask` and update expected sources, pages and answers to what semantic chunking actually returns; re-run the upload demo (`chinh-sach-hoan-tien.docx` with metadata entered in the form) and record the observed timing as one-time observations.
- [ ] **Step 4: Write the sections** (Vietnamese): tech stack; flow diagram (mermaid, ingest and ask, including the `min_score` gate and the SQL filter); DB diagram (mermaid `erDiagram` with fields of `documents`, `pages`, `chunks`, `query_logs`); semantic vs structure chunking table from Step 1; TC1-TC8 results with a diagnosis column; API usage with `curl` examples and `/api/docs`; `min_score` calibration paragraph; known limits (tenant header is a simulation, the HTML viewer is not tenant-scoped, re-uploaded versions leave orphan files in `uploads/`, the SQL filter uses an exact scan, no ANN index).
- [ ] **Step 5: Update existing sections:** directory layout (`config/tenants.yaml`, new `src` files, `evaluation/*`, `uploads/`); section 2 (`docker compose down -v` is required once for the new schema; `ls data/raw` shows the 5 sample files plus any strays, which `scripts/ingest` reports as missing metadata; manifest holds metadata); section 4 figures from Step 1; section 8 (store contract now `start_document(tenant_id:, title:, version:, valid_from:, valid_to:, filename:, path:, sha256:)`, `search(embedding, k, tenant_id:, document_ids:, on:)`, `Ask#call(..., tenant_id:, document_ids:, source:)`, `config/tenants.yaml` beside the other config files).
- [ ] **Step 6: Run** `docker compose run --rm app scripts/test`. Expected: all pass (README is not tested; this guards the earlier tasks).
- [ ] **Step 7: Commit** `git add README.md && git commit -m "docs: NUSAskify report, TC1-TC8 results, API and demo prep"`

---

## Done when

### Automated
- `docker compose run --rm app scripts/test` -> all tests pass, 0 failures, 0 errors.
- `docker compose down -v && docker compose run --rm app scripts/ingest` -> `OK:` lists the 5 preload documents, strays under `Bỏ qua (thiếu metadata)`, exit 0; a second run lists them under `Bỏ qua (không đổi)`.
- `docker compose up -d && docker compose run --rm app evaluation/check_retrieval` -> exit 0, summary line present.
- `docker compose run --rm app evaluation/run_tc` -> TC1-TC7 `PASS`, exit 0.
- `curl -s -H 'X-Tenant-Id: nus' localhost:4567/api/documents` -> JSON; without the header -> 400 `{"error": ...}`.

### Manual
- Chat page: tenant dropdown switches to `acme`, checkboxes reload, an old `nus` conversation does not appear; unchecking everything and sending shows `Chọn ít nhất một tài liệu.`; the `Đoạn tìm được` panel shows title, version, page, score, content; a source link opens `/documents/<id>` on the right page with the quote highlighted.
- Documents page: metadata fields on the upload form, expired v1 visible and marked, delete works and leaves the sample files in `data/raw/` untouched.
- `/api/docs` renders Swagger UI and "Try it out" works with an `X-Tenant-Id` value.
- README: every figure matches the command output recorded in Task 11 step 1; TC8 contains a real `/api/search` output.
