module Rag
  EMBED_MODEL = "Xenova/multilingual-e5-small"
  EMBED_DIM = 384
  MAX_CHUNK_CHARS = 1000 # 1000 Vietnamese chars = 252 tokens (scripts/spikes/RESULTS.md)
  MIN_LETTERS = 20
  TOP_K = 6
  MAX_UPLOAD_BYTES = 30 * 1024 * 1024
  MIN_QUOTE_CHARS = 10
  MAX_PAGES = 200 # every readable page is one paid model call
  MAX_PAGE_CHARS = 20_000

  class Error < StandardError; end

  Page = Struct.new(:number, :raw_text, :markdown, :readable, :fallback, keyword_init: true)
  Chunk = Struct.new(:page, :position, :text, :embedding, keyword_init: true)
  Doc = Struct.new(:id, :filename, :sha256, :status, :error, :page_count, :chunk_count, keyword_init: true)
  Hit = Struct.new(:filename, :page, :text, :distance, keyword_init: true)
end

Dir[File.join(__dir__, "**", "*.rb")].sort.each { |f| require f unless f == __FILE__ || f.start_with?(File.join(__dir__, "web") + "/") }
