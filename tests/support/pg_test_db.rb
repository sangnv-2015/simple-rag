require "pg"

module PgTestDb
  # Connects lazily (only when called), never at require time.
  def self.url
    conn = PG.connect(ENV.fetch("DATABASE_URL"))
    begin
      conn.exec("CREATE DATABASE rag_test")
    rescue PG::DuplicateDatabase
      nil
    ensure
      conn.close
    end
    ENV.fetch("TEST_DATABASE_URL")
  end

  # Tests wipe the documents table: never let that run against a real database.
  def self.clear!(store)
    db = store.send(:exec, "SELECT current_database() AS db").first["db"]
    raise "refusing to clear tables in database #{db.inspect}: name must end with _test" unless db.end_with?("_test")
    store.send(:exec, "TRUNCATE documents RESTART IDENTITY CASCADE")
  end
end
