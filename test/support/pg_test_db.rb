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
end
