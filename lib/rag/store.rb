require "pg"
require "pgvector"

module Rag
  class Store
    def initialize(url)
      @conn = PG.connect(url)
      @conn.exec("SET client_min_messages = warning") # quiet idempotent-DDL notices
      @lock = Mutex.new
    end

    def migrate!
      @lock.synchronize do
        @conn.exec("CREATE EXTENSION IF NOT EXISTS vector")
        registry = ::PG::BasicTypeRegistry.new.register_default_types
        Pgvector::PG.register_vector(registry)
        # after the extension exists: OIDs are looked up when the map is built
        @conn.type_map_for_results = ::PG::BasicTypeMapForResults.new(@conn, registry: registry)
        @conn.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS documents(
            id serial PRIMARY KEY, filename text UNIQUE NOT NULL, sha256 text, status text, error text);
          CREATE TABLE IF NOT EXISTS pages(
            document_id integer NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            number integer, raw_text text, markdown text, readable boolean, fallback boolean);
          CREATE TABLE IF NOT EXISTS chunks(
            document_id integer NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page_number integer, position integer, text text, embedding vector(#{Integer(EMBED_DIM)}));
        SQL
      end
    end

    def find_document(filename)
      doc_rows("WHERE d.filename = $1", [filename]).first
    end

    def start_document(filename:, sha256:)
      @lock.synchronize do
        @conn.transaction do
          @conn.exec_params("DELETE FROM documents WHERE filename = $1", [filename])
          @conn.exec_params(
            "INSERT INTO documents(filename, sha256, status) VALUES ($1, $2, 'processing') RETURNING id",
            [clean(filename), sha256]
          ).first["id"].to_i
        end
      end
    end

    def finish_document(id, pages:, chunks:)
      @lock.synchronize do
        @conn.transaction do
          pages.each do |p|
            @conn.exec_params(
              "INSERT INTO pages(document_id, number, raw_text, markdown, readable, fallback) VALUES ($1,$2,$3,$4,$5,$6)",
              [id, p.number, clean(p.raw_text), clean(p.markdown), p.readable, p.fallback]
            )
          end
          chunks.each do |c|
            @conn.exec_params(
              "INSERT INTO chunks(document_id, page_number, position, text, embedding) VALUES ($1,$2,$3,$4,$5)",
              [id, c.page, c.position, clean(c.text), Pgvector::Vector.new(c.embedding).to_s]
            )
          end
          @conn.exec_params("UPDATE documents SET status = 'done' WHERE id = $1", [id])
        end
      end
      nil
    end

    def fail_document(id, message)
      exec("UPDATE documents SET status = 'error', error = $2 WHERE id = $1", [id, clean(message)])
      nil
    end

    def documents = doc_rows("", [])

    def pages(filename)
      exec(<<~SQL, [filename]).map do |r|
        SELECT p.number, p.raw_text, p.markdown, p.readable, p.fallback
        FROM pages p JOIN documents d ON d.id = p.document_id
        WHERE d.filename = $1 ORDER BY p.number
      SQL
        Page.new(number: r["number"].to_i, raw_text: r["raw_text"], markdown: r["markdown"],
                 readable: r["readable"], fallback: r["fallback"])
      end
    end

    def search(embedding, k)
      exec(<<~SQL, [Pgvector::Vector.new(embedding).to_s, k]).map do |r|
        SELECT d.filename, c.page_number, c.text, c.embedding <=> $1 AS distance
        FROM chunks c JOIN documents d ON d.id = c.document_id
        ORDER BY distance LIMIT $2
      SQL
        Hit.new(filename: r["filename"], page: r["page_number"].to_i, text: r["text"], distance: r["distance"].to_f)
      end
    end

    private

    def exec(sql, params = [])
      @lock.synchronize { @conn.exec_params(sql, params).to_a }
    end

    # Postgres rejects NUL in text; bad extraction can produce it.
    def clean(s) = s&.delete("\u0000")

    def doc_rows(where, params)
      exec(<<~SQL, params).map do |r|
        SELECT d.id, d.filename, d.sha256, d.status, d.error,
          (SELECT count(*) FROM pages p WHERE p.document_id = d.id) AS page_count,
          (SELECT count(*) FROM chunks c WHERE c.document_id = d.id) AS chunk_count
        FROM documents d #{where} ORDER BY d.filename
      SQL
        Doc.new(id: r["id"].to_i, filename: r["filename"], sha256: r["sha256"], status: r["status"],
                error: r["error"], page_count: r["page_count"].to_i, chunk_count: r["chunk_count"].to_i)
      end
    end
  end
end
