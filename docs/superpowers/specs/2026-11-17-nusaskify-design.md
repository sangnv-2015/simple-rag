# NUSAskify: multi-tenant, versioned RAG on the existing app

Date: 2026-11-17. Requirement source: `NUS_AI_Training_RAG_Assignment_Requirement_0_1.md` (assignment "RAG Assignment: NUSAskify - Internal Policy Q&A"; summarised below so this doc stands alone).

## Intent

Turn the existing Ruby RAG demo into the NUSAskify assignment submission, scoring all four criteria: database + ingestion (25), API + docs (25), frontend (20), test cases + diagnosis (30). The existing app must keep working as it does today (chat page, streaming, follow-up rewriting, document page with raw/markdown columns, `scripts/ingest`, the README demo script), now running inside a default tenant.

## Goals

1. Data model with `documents` (tenant, title, version, validity, status), `chunks` (id, index, vector) and a new `query_logs`.
2. Ingestion: PDF/DOCX only (already), **semantic chunking** as the default chunker, structure chunking kept for comparison, required metadata enforced, new version expires the old one.
3. JSON API under `/api/*` with `X-Tenant-Id`, plus interactive docs (Swagger UI).
4. Filtering by tenant, selected documents and validity **inside the SQL, before top-k**; score threshold that returns "not enough information" without calling the LLM.
5. Chat page gains a tenant dropdown, document checkboxes, and a "retrieved chunks" panel (document, version, page, score, content).
6. Sample data and scripts that exercise TC1-TC8; README report (stack, flow diagram, DB diagram, chunking comparison, TC1-TC8 results, run instructions).

## Non-goals

- Authentication or real multi-tenancy security: the tenant header is a simulation, as the assignment says.
- OCR, new file types, streaming on `/api/ask`, conversation history on `/api/ask` (single turn).
- Tenant management UI (tenants come from config).
- Replacing DeepSeek or the embedding model.

## Anti-goals (failure even if it "works")

- The existing demo flow breaks or silently changes behaviour for the default tenant.
- A chunk from another tenant, an unselected document, or an expired version reaches the LLM or the chunk list (filtering after top-k counts as this failure).
- A citation that does not point to a retrieved chunk.
- Ingestion indexes a document with missing metadata.

## Constraints

- Ruby, Sinatra 4, Puma, Postgres + pgvector, `informers` (`Xenova/multilingual-e5-small`, 384 dims), DeepSeek via the company gateway. No new gems unless unavoidable; Swagger UI loads from a CDN.
- Settings validated at load in `src/rag.rb` (`load_settings`); new settings follow that pattern.
- Source mounted read-only in Docker; only `data/raw/` and the model cache are writable.
- Existing tests must keep passing (updated only where identity changes from filename to id).
- `CREATE TABLE IF NOT EXISTS` migrations today; an existing `pgdata` volume will not get new columns. Acceptable to require `docker compose down -v` once (document it) or add `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`; builder's call.

## Approaches considered

- **A. Extend the shared core (chosen by the user).** Add tenant/version/validity to the existing tables; old app runs in the default tenant; `/api/*` and the UI share store, ingest and ask. One codebase, one dataset; cost: removing `filename UNIQUE` ripples through ingest, links and tests.
- B. Separate NUSAskify app with its own Postgres schema, reusing extract/embed/chunk. Zero risk to the old app, but two stores and two ingest paths.
- C. Separate branch/repo. Rejected: diverges, assignment grades one repo.

UI sub-decision (user chose 1): extend the existing chat page rather than add a second single-turn page.

## Design

### Data model

```
documents(id serial PK, tenant_id text NOT NULL, title text NOT NULL, version integer NOT NULL,
          valid_from date NOT NULL, valid_to date NOT NULL, filename text NOT NULL, path text NOT NULL,
          sha256 text, status text, error text, created_at timestamptz DEFAULT now(),
          UNIQUE (tenant_id, title, version))
  status: processing | done | failed | expired
  index on (tenant_id, status)
pages(document_id FK CASCADE, number, raw_text, markdown, readable, fallback)   -- unchanged
chunks(id serial PK, document_id FK CASCADE, chunk_index integer, page_number integer,
       text text, embedding vector(384))
  index on document_id
query_logs(id serial PK, tenant_id text, question text, standalone text, document_ids integer[],
           retrieved_chunk_ids integer[], scores real[], status text, answer text,
           cited_chunk_ids integer[], source text /* 'web' | 'api' */, created_at timestamptz DEFAULT now())
```

- "Same document" = same `(tenant_id, title)`. When a version finishes ingesting, every other `done` version of that `(tenant_id, title)` with a lower version becomes `expired` and its `valid_to` is set to the new version's `valid_from` (if later). Chunks of expired versions are kept (debuggable via `/api/documents/:id/chunks`) and excluded by the search filter.
- Uploading a version that already exists for `(tenant_id, title, version)` replaces it (current re-upload behaviour, now keyed by that triple instead of filename). Identical sha256 + `done` → skipped, as today.
- Score = `1 - cosine distance` (pgvector `<=>`), reported to 3 decimals.
- Tenants: new `config/tenants.yaml` (`tenants: [nus, acme]`, `default: nus`), validated at load. Unknown `X-Tenant-Id` → 400.

### Ingestion

- Metadata required: `tenant_id`, `title`, `version` (positive integer), `valid_from`, `valid_to` (ISO dates, `valid_from <= valid_to`). Missing or invalid → rejected with a clear message, nothing stored (422 on web/API).
- `scripts/ingest` reads metadata from `data/samples/manifest.yml` (entries gain `tenant`, `title`, `version`, `valid_from`, `valid_to`). Files in `data/raw/` without a manifest entry are reported as `Bỏ qua (thiếu metadata)` and not ingested (exit 0) (this also stops the two stray PDFs in `data/raw/` from costing paid calls).
- Uploads are saved under `data/raw/uploads/<tenant>/<uuid>-<filename>` so equal filenames across tenants/versions don't collide; `documents.path` stores it. `scripts/ingest` does not scan `uploads/`.
- Pipeline unchanged up to the restructured page text (extract → DeepSeek restructure per page → fallback to raw). Then chunking per `chunking:` in `config/retriever.yaml` (`semantic` default, `structure` = current `Chunker`).
- **SemanticChunker** (`src/chunking/semantic_chunker.rb`), built by hand, per page: split into sentences (sentence ends, line breaks; markdown table rows and headings are kept as single units, headings attach to what follows), embed each unit with the same embedder, cosine between neighbours, start a new chunk when similarity < threshold **or** the chunk would exceed `max_chunk_chars`. Threshold mode: percentile of the page's neighbour similarities (`semantic_breakpoint_percentile`, e.g. 25th → cut at the lowest quarter), with a fixed-floor fallback for pages with too few units. Pure function given an embed callback, so it is unit-testable with a fake embedder.
- Embedding at ingest: unit embeddings for chunking, then chunk embeddings with `embed_passages` (same model as queries, which use `embed_query`).

### Retrieval and answering

- `store.search(embedding, k, tenant_id:, document_ids:, on: Date.today)` with `WHERE d.tenant_id = $ AND d.status = 'done' AND $on BETWEEN d.valid_from AND d.valid_to AND (document_ids empty OR d.id = ANY($))`, then `ORDER BY distance LIMIT k`. Empty `document_ids` = all of the tenant's documents (needed for the chat page default and `scripts/ask`).
- `Hit` gains `chunk_id`, `document_id`, `title`, `version`, `score`.
- `min_score` in `config/retriever.yaml`: if no hit or best score < `min_score`, answer is "not enough information" without calling the LLM. The value is calibrated on the sample question set (record in README how).
- The LLM path, quote verification and NOT_FOUND handling stay as in `Rag::Ask`. A citation `[Sn]` outside the hit list is already dropped; citations returned by the API carry `chunk_id`, so TC7 can be checked mechanically.
- Every ask (web or API) writes one `query_logs` row; a logging failure must not fail the answer.

### API (JSON, English)

All `/api/*` read `X-Tenant-Id` (missing → default tenant is NOT applied: 400 with message; the web UI always sends it).

| Method | Path | Body / result |
|---|---|---|
| POST | `/api/documents` | multipart `file` + `tenant_id` taken from header, `title`, `version`, `valid_from`, `valid_to` → 202 `{id, status}`; ingestion runs on the existing worker queue |
| GET | `/api/documents` | tenant's documents: id, title, version, filename, valid_from, valid_to, status, chunk_count |
| GET | `/api/documents/:id/chunks` | chunks (id, chunk_index, page, text) of that document; 404 if other tenant |
| DELETE | `/api/documents/:id` | deletes document, pages, chunks and the uploaded file; 404 if other tenant |
| POST | `/api/search` | `{question, document_ids, top_k}` → `{chunks: [{chunk_id, document_id, title, version, page, score, content}]}`, no LLM |
| POST | `/api/ask` | `{question, document_ids}` → `{status: "answered" | "not_enough_information", answer, citations: [{n, chunk_id, document_id, title, version, page, quote}], chunks: [...as search]}` |

- Docs: hand-written `src/web/openapi.yaml` served at `/api/openapi.yaml`, Swagger UI page at `/api/docs` (CDN, pinned version).
- Existing host check (localhost only) and body size limits apply to `/api/*` too. The existing origin check for POSTs must allow Swagger UI calls from the same origin.

### Web UI (existing chat page, extended)

```
[Tenant: nus ▾]                                   [New chat]
Phạm vi: ☑ Quy chế nghỉ phép (v2)  ☑ Làm việc từ xa (v1)  ☐ Travel expense (v1)
────────────────────────────────────────────────────────────
Bạn: Làm ở nhà được mấy ngày/tuần?
Bot: Tối đa 2 ngày/tuần [1]
     ▸ Đoạn tìm được (6)
       [1] Làm việc từ xa v1 · tr.1 · 0.821  "Nhân viên được làm việc từ xa..."
```

- Tenant dropdown (from config; choice remembered in localStorage) sent as `X-Tenant-Id` on `/ask` and document list calls. Switching tenant reloads the document checkboxes; conversations are per tenant or cleared on switch (builder's call, must not mix tenants in one conversation).
- Checkboxes list the tenant's `done`, currently valid documents; default all checked. Selected ids go in the `/ask` body.
- The `done` SSE event additionally carries the retrieved chunks; the panel shows title, version, page, score, content. Sources link to `/documents/:id?page=N&q=...`.
- Documents page: list scoped to the selected tenant, shows title/version/validity/status (expired visible but marked), upload form gains the metadata fields (title prefilled from filename, version 1, valid_from today), delete button.
- Default behaviour (tenant `nus`, all checked) runs today's demo flow; answers may differ because of semantic chunking (see "Decided by the user").

### Sample data and test cases

- Existing 3 preload docs → tenant `nus`, version 1, validity covering today.
- Add (via `data/samples/src` + `scripts/build_samples`): an **expired** older version of the leave policy (`nus`, v1, different numbers, valid until last year; the current leave policy becomes v2), and an **`acme`** tenant document on an overlapping topic with distinct numbers (e.g. acme remote work policy).
- `evaluation/questions.yml` extended with TC tags; new `evaluation/run_tc` hits the API (`/api/search`, `/api/ask`) and prints a pass/fail table for TC1-TC7 (TC3 checks status, TC4 checks no expired chunk ids, TC5 switches header, TC6 selects one doc, TC7 checks every citation chunk_id ∈ retrieved ids and quote verified). TC8 (similarity failure mode) is found manually and documented with the `/api/search` output.
- `evaluation/compare_chunking` re-chunks the preload docs both ways in memory (no DB writes, reuses stored page markdown or raw text), runs the question set, prints chunk counts, average size, hit@k and rank of the right chunk per question, for the README.

### README report (Vietnamese, added sections)

Tech stack; flow diagram (ingest and ask, mermaid); DB diagram with fields (mermaid erDiagram); semantic vs structure chunking table from `compare_chunking`; TC1-TC8 results with diagnosis (retrieval vs generation); API usage and `/api/docs`; updated demo prep (manifest metadata, `down -v` once for the new schema).

## Assignment test cases (verbatim from the requirement)

| # | Scenario | Expected |
|---|---|---|
| TC1 | Question worded differently from the document | Correct chunk retrieved; correct answer with a citation |
| TC2 | Call `/api/search` with the TC1 question | Record the top 3 chunks with scores; explain why semantic search finds the chunk when the words don't match |
| TC3 | Question not covered by any document | Return "not enough information"; no made-up answer |
| TC4 | Expired version and current version both uploaded | Only the current version is used |
| TC5 | Switch to another tenant | No chunks from the other tenant |
| TC6 | Select only document A, ask about document B | No chunks from B |
| TC7 | Check citations | Every citation points to a retrieved chunk that actually supports the claim |
| TC8 | Failure mode of similarity | A case where the "most similar" chunk is not the right answer |

API paths and the `/api/search` / `/api/ask` body and result fields in the API table above are the ones the requirement fixes (`{ question, document_ids, top_k }`, `{ status, answer, citations, chunks }`). `run_tc` covers TC1-TC7; TC2 additionally prints the top 3 with scores for the README.

## Decided by the user during review

- **Semantic chunking is the default, unconditionally.** If it changes the README demo answers or `check_retrieval` results, update the README's expected answers and figures to match; do not fall back to `structure` to preserve the old demo. "Existing app keeps working" means its features keep working, not that its answers stay byte-identical.

## Calls made during review (designer's, correctable)

- A lower version that finishes ingesting while a higher `done` version of the same `(tenant_id, title)` exists is marked `expired` itself. Deleting a version never revives an older one.
- `scripts/ingest`: files in `data/raw/` with no manifest entry are listed as `Bỏ qua (thiếu metadata): ...`, not indexed, and do not make the script exit 1.
- On the web, "below `min_score`" shows the same `Không tìm thấy thông tin này trong tài liệu.` view as today's NOT_FOUND; the API returns `status: "not_enough_information"` for both.

## Left to the builder

- Sentence splitter details, percentile vs floor numbers, `min_score` value (calibrate and record).
- Migration style (fresh volume vs `ALTER ... IF NOT EXISTS`).
- How conversations behave on tenant switch (within the anti-goal above).
- Exact Swagger UI CDN version; error JSON shape (`{error: "..."}` suggested).
