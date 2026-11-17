require "yaml"
require "date"

module Rag
  class Error < StandardError; end

  # Reads a YAML mapping and checks every key in schema (key => :integer, :number, :string or :boolean).
  # Raises Rag::Error naming the file and key, so a bad setting fails when the core loads.
  def self.load_settings(path, schema)
    name = "config/#{File.basename(path)}"
    data = YAML.safe_load_file(path)
    raise Error, "#{name}: must be a mapping of settings" unless data.is_a?(Hash)
    types = {integer: ["an integer", ->(v) { v.is_a?(Integer) }], number: ["a number", ->(v) { v.is_a?(Numeric) }],
             string: ["a string", ->(v) { v.is_a?(String) && !v.empty? }], boolean: ["true or false", ->(v) { v == true || v == false }],
             string_list: ["a list of strings", ->(v) { v.is_a?(Array) && !v.empty? && v.all? { |s| s.is_a?(String) && !s.empty? } }]}
    schema.each do |key, type|
      raise Error, "#{name}: missing key #{key}" unless data.key?(key)
      want, ok = types.fetch(type)
      raise Error, "#{name}: #{key} must be #{want}" unless ok.call(data[key])
    end
    data.freeze
  end

  # config/tenants.yaml: the tenant ids and which one the web UI and CLI default to.
  def self.load_tenants(path)
    data = load_settings(path, "tenants" => :string_list, "default" => :string)
    raise Error, "config/tenants.yaml: default must be one of tenants" unless data["tenants"].include?(data["default"])
    data
  end

  # Settings live in config/*.yaml (non-secret), checked once here: a bad or missing key raises at load time.
  CONFIG_DIR = File.expand_path("../config", __dir__)
  RETRIEVER_SETTINGS = load_settings(File.join(CONFIG_DIR, "retriever.yaml"),
    "embed_model" => :string, "embed_dim" => :integer, "top_k" => :integer, "max_chunk_chars" => :integer,
    "min_letters" => :integer, "min_quote_chars" => :integer, "max_pages" => :integer,
    "max_page_chars" => :integer, "max_upload_mb" => :integer, "chunking" => :string, "min_score" => :number,
    "semantic_breakpoint_percentile" => :integer, "semantic_floor" => :number, "semantic_min_units" => :integer)
  TENANT_SETTINGS = load_tenants(File.join(CONFIG_DIR, "tenants.yaml"))
  LLM_SETTINGS = load_settings(File.join(CONFIG_DIR, "llm.yaml"),
    "default_model" => :string, "temperature" => :number, "read_timeout" => :integer, "disable_reasoning" => :boolean)

  EMBED_MODEL = RETRIEVER_SETTINGS.fetch("embed_model")
  EMBED_DIM = RETRIEVER_SETTINGS.fetch("embed_dim")
  MAX_CHUNK_CHARS = RETRIEVER_SETTINGS.fetch("max_chunk_chars")
  MIN_LETTERS = RETRIEVER_SETTINGS.fetch("min_letters")
  TOP_K = RETRIEVER_SETTINGS.fetch("top_k")
  MAX_UPLOAD_BYTES = RETRIEVER_SETTINGS.fetch("max_upload_mb") * 1024 * 1024
  MIN_QUOTE_CHARS = RETRIEVER_SETTINGS.fetch("min_quote_chars")
  MAX_PAGES = RETRIEVER_SETTINGS.fetch("max_pages")
  MAX_PAGE_CHARS = RETRIEVER_SETTINGS.fetch("max_page_chars")

  TENANTS = TENANT_SETTINGS.fetch("tenants").freeze
  DEFAULT_TENANT = TENANT_SETTINGS.fetch("default")
  CHUNKING = RETRIEVER_SETTINGS.fetch("chunking")
  raise Error, "config/retriever.yaml: chunking must be semantic or structure" unless %w[semantic structure].include?(CHUNKING)
  MIN_SCORE = RETRIEVER_SETTINGS.fetch("min_score").to_f
  SEMANTIC_PERCENTILE = RETRIEVER_SETTINGS.fetch("semantic_breakpoint_percentile")
  raise Error, "config/retriever.yaml: semantic_breakpoint_percentile must be between 1 and 99" unless (1..99).cover?(SEMANTIC_PERCENTILE)
  SEMANTIC_FLOOR = RETRIEVER_SETTINGS.fetch("semantic_floor").to_f
  SEMANTIC_MIN_UNITS = RETRIEVER_SETTINGS.fetch("semantic_min_units")

  Page = Struct.new(:number, :raw_text, :markdown, :readable, :fallback, keyword_init: true)
  Chunk = Struct.new(:page, :position, :text, :embedding, :id, keyword_init: true)
  Doc = Struct.new(:id, :filename, :sha256, :status, :error, :page_count, :chunk_count,
                :tenant_id, :title, :version, :valid_from, :valid_to, :path, keyword_init: true) do
    def current?(on = Date.today) = status == "done" && valid_from <= on && on <= valid_to
  end
  Hit = Struct.new(:filename, :page, :text, :distance, :chunk_id, :document_id, :title, :version, keyword_init: true) do
    def score = 1.0 - distance
  end
end

Dir[File.join(__dir__, "**", "*.rb")].sort.each { |f| require f unless f == __FILE__ || f.start_with?(File.join(__dir__, "web") + "/") }
