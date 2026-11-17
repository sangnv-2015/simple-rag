require "yaml"

module Rag
  # Settings live in config/*.yaml (non-secret); a missing key raises KeyError at load time.
  CONFIG_DIR = File.expand_path("../config", __dir__)
  RETRIEVER_SETTINGS = YAML.safe_load_file(File.join(CONFIG_DIR, "retriever.yaml")).freeze
  LLM_SETTINGS = YAML.safe_load_file(File.join(CONFIG_DIR, "llm.yaml")).freeze

  EMBED_MODEL = RETRIEVER_SETTINGS.fetch("embed_model")
  EMBED_DIM = RETRIEVER_SETTINGS.fetch("embed_dim")
  MAX_CHUNK_CHARS = RETRIEVER_SETTINGS.fetch("max_chunk_chars")
  MIN_LETTERS = RETRIEVER_SETTINGS.fetch("min_letters")
  TOP_K = RETRIEVER_SETTINGS.fetch("top_k")
  MAX_UPLOAD_BYTES = RETRIEVER_SETTINGS.fetch("max_upload_mb") * 1024 * 1024
  MIN_QUOTE_CHARS = RETRIEVER_SETTINGS.fetch("min_quote_chars")
  MAX_PAGES = RETRIEVER_SETTINGS.fetch("max_pages")
  MAX_PAGE_CHARS = RETRIEVER_SETTINGS.fetch("max_page_chars")

  class Error < StandardError; end

  Page = Struct.new(:number, :raw_text, :markdown, :readable, :fallback, keyword_init: true)
  Chunk = Struct.new(:page, :position, :text, :embedding, keyword_init: true)
  Doc = Struct.new(:id, :filename, :sha256, :status, :error, :page_count, :chunk_count, keyword_init: true)
  Hit = Struct.new(:filename, :page, :text, :distance, keyword_init: true)
end

Dir[File.join(__dir__, "**", "*.rb")].sort.each { |f| require f unless f == __FILE__ || f.start_with?(File.join(__dir__, "web") + "/") }
