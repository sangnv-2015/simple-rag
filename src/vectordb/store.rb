require "pg"
require "pgvector"

module Rag
  class Store
    def initialize(url)
      @conn = PG.connect(url)
      setup_connection
      @conn.type_map_for_results = ::PG::BasicTypeMapForResults.new(@conn)
      @lock = Mutex.new
    end

    def migrate!
      with_conn do
        @conn.exec("CREATE EXTENSION IF NOT EXISTS vector")
        registry = ::PG::BasicTypeRegistry.new.register_default_types
        Pgvector::PG.register_vector(registry)
        # after the extension exists: OIDs are looked up when the map is built
        @conn.type_map_for_results = ::PG::BasicTypeMapForResults.new(@conn, registry: registry)
        old = @conn.exec(<<~SQL).any?
          SELECT 1 FROM information_schema.tables t WHERE t.table_schema = current_schema() AND t.table_name = 'documents'
            AND NOT EXISTS (SELECT 1 FROM information_schema.columns c
              WHERE c.table_schema = current_schema() AND c.table_name = 'documents' AND c.column_name = 'tenant_id')
        SQL
        raise Error, "Cơ sở dữ liệu có schema cũ. Chạy `docker compose down -v` một lần để tạo lại." if old
        @conn.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS documents(
            id serial PRIMARY KEY, tenant_id text NOT NULL, title text NOT NULL, version integer NOT NULL,
            valid_from date NOT NULL, valid_to date NOT NULL, filename text NOT NULL, path text, sha256 text,
            status text, error text, UNIQUE (tenant_id, title, version));
          CREATE INDEX IF NOT EXISTS documents_tenant_status ON documents(tenant_id, status);
          CREATE TABLE IF NOT EXISTS pages(
            document_id integer NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            number integer, raw_text text, markdown text, readable boolean, fallback boolean);
          CREATE TABLE IF NOT EXISTS chunks(
            id serial PRIMARY KEY,
            document_id integer NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page_number integer, chunk_index integer, text text, embedding vector(#{Integer(EMBED_DIM)}));
          CREATE INDEX IF NOT EXISTS chunks_document ON chunks(document_id);
          CREATE TABLE IF NOT EXISTS query_logs(
            id serial PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now(), tenant_id text NOT NULL,
            question text, standalone text, document_ids integer[], retrieved_chunk_ids integer[], scores real[],
            status text, answer text, cited_chunk_ids integer[], source text);
        SQL
      end
    end

    def find_document(tenant_id:, title:, version:)
      doc_rows("WHERE d.tenant_id = $1 AND d.title = $2 AND d.version = $3", [tenant_id, title, version]).first
    end

    def document(id, tenant_id: nil)
      doc_rows("WHERE d.id = $1 AND ($2::text IS NULL OR d.tenant_id = $2)", [id, tenant_id]).first
    end

    def start_document(tenant_id:, title:, version:, valid_from:, valid_to:, filename:, path:, sha256:)
      with_conn do
        @conn.transaction do
          @conn.exec_params("DELETE FROM documents WHERE tenant_id = $1 AND title = $2 AND version = $3",
                            [tenant_id, title, version])
          @conn.exec_params(<<~SQL, [tenant_id, title, version, valid_from.iso8601, valid_to.iso8601, filename, path, sha256]).first["id"].to_i
            INSERT INTO documents(tenant_id, title, version, valid_from, valid_to, filename, path, sha256, status)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'processing') RETURNING id
          SQL
        end
      end
    end

    # Dates only: status stays (an expired version stays expired).
    def update_validity(id, valid_from:, valid_to:)
      exec("UPDATE documents SET valid_from = $2::date, valid_to = $3::date WHERE id = $1", [id, valid_from.iso8601, valid_to.iso8601])
      nil
    end

    def finish_document(id, pages:, chunks:)
      with_conn do
        @conn.transaction do
          # Deleted while ingesting: fail cleanly before touching pages/chunks.
          raise Rag::Error, "Tài liệu đã bị xóa trong khi xử lý." if @conn.exec_params("SELECT 1 FROM documents WHERE id = $1 FOR UPDATE", [id]).ntuples.zero?
          pages.each do |p|
            @conn.exec_params(
              "INSERT INTO pages(document_id, number, raw_text, markdown, readable, fallback) VALUES ($1,$2,$3,$4,$5,$6)",
              [id, p.number, clean(p.raw_text), clean(p.markdown), p.readable, p.fallback]
            )
          end
          chunks.each do |c|
            @conn.exec_params(
              "INSERT INTO chunks(document_id, page_number, chunk_index, text, embedding) VALUES ($1,$2,$3,$4,$5)",
              [id, c.page, c.position, clean(c.text), Pgvector::Vector.new(c.embedding).to_s]
            )
          end
          @conn.exec_params("UPDATE documents SET status = 'done' WHERE id = $1", [id])
          expire_versions(id)
        end
      end
      nil
    end

    def fail_document(id, message)
      exec("UPDATE documents SET status = 'error', error = $2 WHERE id = $1", [id, clean(message)])
      nil
    end

    def documents(tenant_id: nil) = doc_rows("WHERE ($1::text IS NULL OR d.tenant_id = $1)", [tenant_id])

    def delete_document(id, tenant_id:)
      with_conn do
        @conn.transaction do
          doc = doc_rows_unlocked("WHERE d.id = $1 AND d.tenant_id = $2", [id, tenant_id]).first
          @conn.exec_params("DELETE FROM documents WHERE id = $1", [id]) if doc
          doc
        end
      end
    end

    def pages(document_id)
      exec(<<~SQL, [document_id]).map do |r|
        SELECT number, raw_text, markdown, readable, fallback FROM pages WHERE document_id = $1 ORDER BY number
      SQL
        Page.new(number: r["number"].to_i, raw_text: r["raw_text"], markdown: r["markdown"],
                 readable: r["readable"], fallback: r["fallback"])
      end
    end

    def chunks(document_id)
      exec("SELECT id, page_number, chunk_index, text FROM chunks WHERE document_id = $1 ORDER BY chunk_index, id",
           [document_id]).map do |r|
        Chunk.new(id: r["id"].to_i, page: r["page_number"].to_i, position: r["chunk_index"].to_i, text: r["text"])
      end
    end

    # No ANN index on purpose: the tenant/validity/document filter is applied before top-k.
    def search(embedding, k, tenant_id:, document_ids: [], on: Date.today)
      params = [Pgvector::Vector.new(embedding).to_s, k, tenant_id, on.iso8601, int_array(document_ids)]
      exec(<<~SQL, params).map do |r|
        SELECT d.filename, d.title, d.version, d.id AS document_id, c.id AS chunk_id, c.page_number, c.text,
          c.embedding <=> $1 AS distance
        FROM chunks c JOIN documents d ON d.id = c.document_id
        WHERE d.tenant_id = $3 AND d.status = 'done' AND $4::date BETWEEN d.valid_from AND d.valid_to
          AND (cardinality($5::integer[]) = 0 OR d.id = ANY($5::integer[]))
        ORDER BY distance LIMIT $2
      SQL
        Hit.new(filename: r["filename"], page: r["page_number"].to_i, text: r["text"], distance: r["distance"].to_f,
                chunk_id: r["chunk_id"].to_i, document_id: r["document_id"].to_i, title: r["title"], version: r["version"].to_i)
      end
    end

    def log_query(tenant_id:, question:, standalone:, document_ids:, retrieved_chunk_ids:, scores:, status:, answer:,
                  cited_chunk_ids:, source:)
      params = [tenant_id, question, standalone, int_array(document_ids), int_array(retrieved_chunk_ids),
                "{#{scores.map { |x| Float(x) }.join(",")}}", status, answer, int_array(cited_chunk_ids), source]
      exec(<<~SQL, params)
        INSERT INTO query_logs(tenant_id, question, standalone, document_ids, retrieved_chunk_ids, scores, status,
          answer, cited_chunk_ids, source) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
      SQL
      nil
    end

    def query_logs(limit: 100)
      exec("SELECT * FROM query_logs ORDER BY created_at DESC, id DESC LIMIT $1", [Integer(limit)])
    end

    private

    def setup_connection
      @conn.exec("SET client_min_messages = warning") # quiet idempotent-DDL notices
    end

    # One connection, one mutex. On a dropped connection reset and retry the whole block once
    # (transactions are fully contained in the block, so the retry starts clean).
    def with_conn
      @lock.synchronize do
        retried = false
        begin
          yield
        rescue PG::ConnectionBad, PG::UnableToSend
          raise if retried
          retried = true
          @conn.reset
          setup_connection
          retry
        end
      end
    end

    def exec(sql, params = [])
      with_conn { @conn.exec_params(sql, params).to_a }
    end

    # Postgres rejects NUL in text; bad extraction can produce it.
    def clean(s) = s&.delete("\u0000")

    def int_array(ids) = "{#{ids.map { |i| Integer(i) }.join(",")}}"

    # Same title in the same tenant: a newer finished version retires the older ones (never the reverse).
    def expire_versions(id)
      me = @conn.exec_params("SELECT tenant_id, title, version, valid_from FROM documents WHERE id = $1", [id]).first
      same = [me["tenant_id"], me["title"], me["version"]]
      newer = @conn.exec_params(<<~SQL, same).any?
        SELECT 1 FROM documents WHERE tenant_id = $1 AND title = $2 AND status = 'done' AND version > $3
      SQL
      if newer
        @conn.exec_params("UPDATE documents SET status = 'expired' WHERE id = $1", [id])
      else
        @conn.exec_params(<<~SQL, same + [me["valid_from"].iso8601])
          UPDATE documents SET status = 'expired', valid_to = LEAST(valid_to, $4::date)
          WHERE tenant_id = $1 AND title = $2 AND status = 'done' AND version < $3
        SQL
      end
    end

    def doc_rows(where, params) = with_conn { doc_rows_unlocked(where, params) }

    def doc_rows_unlocked(where, params)
      @conn.exec_params(<<~SQL, params).map do |r|
        SELECT d.id, d.filename, d.sha256, d.status, d.error, d.tenant_id, d.title, d.version, d.valid_from, d.valid_to, d.path,
          (SELECT count(*) FROM pages p WHERE p.document_id = d.id) AS page_count,
          (SELECT count(*) FROM chunks c WHERE c.document_id = d.id) AS chunk_count
        FROM documents d #{where} ORDER BY d.title, d.version DESC, d.id
      SQL
        Doc.new(id: r["id"].to_i, filename: r["filename"], sha256: r["sha256"], status: r["status"],
                error: r["error"], page_count: r["page_count"].to_i, chunk_count: r["chunk_count"].to_i,
                tenant_id: r["tenant_id"], title: r["title"], version: r["version"].to_i,
                valid_from: r["valid_from"], valid_to: r["valid_to"], path: r["path"])
      end
    end
  end
end
