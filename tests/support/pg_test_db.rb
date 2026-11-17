require "pg"

module PgTestDb
  # Connects lazily (only when called), never at require time.
  # Dropped and recreated once per process so an old-schema volume cannot break tests.
  def self.url
    @url ||= begin
      conn = PG.connect(ENV.fetch("DATABASE_URL"))
      begin
        conn.exec("DROP DATABASE IF EXISTS rag_test WITH (FORCE)")
        conn.exec("CREATE DATABASE rag_test")
      ensure
        conn.close
      end
      ENV.fetch("TEST_DATABASE_URL")
    end
  end

  # Tests wipe the documents table: never let that run against a real database.
  def self.clear!(store)
    db = store.send(:exec, "SELECT current_database() AS db").first["db"]
    raise "refusing to clear tables in database #{db.inspect}: name must end with _test" unless db.end_with?("_test")
    store.send(:exec, "TRUNCATE documents, query_logs RESTART IDENTITY CASCADE")
  end
end
