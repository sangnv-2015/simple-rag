module Rag
  class ConfigError < Error; end

  Config = Struct.new(:api_key, :api_base, :model, :database_url, :documents_dir) do
    REQUIRED = { "DEEPSEEK_API_KEY" => :api_key, "DEEPSEEK_API_BASE" => :api_base }.freeze

    def self.from_env(env = ENV)
      missing = REQUIRED.keys.select { |k| env[k].to_s.strip.empty? }
      raise ConfigError, "Thiếu biến môi trường: #{missing.join(", ")}. Hãy điền trong file .env (xem .env.example)." unless missing.empty?
      new(env["DEEPSEEK_API_KEY"], env["DEEPSEEK_API_BASE"], env["DEEPSEEK_MODEL"].to_s.strip.then { |m| m.empty? ? "deepseek-flash" : m },
          env["DATABASE_URL"], env["DOCUMENTS_DIR"] || File.expand_path("../../documents", __dir__))
    end

    def inspect = "#<Rag::Config model=#{model.inspect} documents_dir=#{documents_dir.inspect}>"
    alias_method :to_s, :inspect
  end

  System = Struct.new(:config, :store, :ingest, :ask)

  def self.build(config = Config.from_env)
    store = Store.new(config.database_url)
    store.migrate!
    embedder = Embedder.new
    llm = DeepSeek.new(api_key: config.api_key, base_url: config.api_base, model: config.model)
    System.new(config, store, Ingest.new(llm: llm, embedder: embedder, store: store), Ask.new(llm: llm, embedder: embedder, store: store))
  end
end
