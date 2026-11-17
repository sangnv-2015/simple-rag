class FakeLLM
  attr_reader :calls

  def initialize(&reply)
    @reply = reply
    @calls = []
  end

  def chat(messages, &on_delta)
    @calls << { messages: messages, streamed: !on_delta.nil? }
    out = @reply.call(messages)
    raise out if out.is_a?(Exception)
    out = [out] if out.is_a?(String)
    out.each { |d| on_delta.call(d) } if on_delta
    out.join
  end
end

require "zlib"

class FakeEmbedder
  attr_reader :inputs

  def initialize
    @inputs = []
  end

  def embed_passages(texts)
    @inputs << texts
    texts.map { |t| vector(t) }
  end

  def embed_query(text) = vector(text)

  private

  def vector(text)
    v = Array.new(Rag::EMBED_DIM, 0.0)
    text.downcase.scan(/\p{L}+|\d+/).each { |w| v[Zlib.crc32(w) % Rag::EMBED_DIM] += 1.0 }
    norm = Math.sqrt(v.sum { |x| x * x })
    norm.zero? ? v : v.map { |x| x / norm }
  end
end

class FakeExtractor
  attr_reader :calls

  def initialize(files)
    @files = files
    @calls = []
  end

  def pages(path)
    @calls << path
    r = @files.fetch(File.basename(path))
    raise r if r.is_a?(Exception)
    r.map(&:dup)
  end
end

module TestMeta
  def self.attrs(filename, **over)
    { tenant_id: "nus", title: filename, version: 1, valid_from: Date.new(2000, 1, 1), valid_to: Date.new(2999, 12, 31),
      filename: filename, path: "/x/#{filename}", sha256: "h" }.merge(over)
  end

  def by_name(store, filename) = store.documents.find { |d| d.filename == filename }
  module_function :by_name
end

# Test files call by_name(...) unqualified.
Minitest::Test.include(TestMeta) if defined?(Minitest::Test)

class FakeWorker
  attr_reader :enqueued
  attr_accessor :names

  def initialize = (@enqueued, @names = [], [])
  def enqueue(key, *args) = @enqueued << [key, *args]
  def pending = @names
end
