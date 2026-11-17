class FakeStore
  def initialize
    @docs = {} # id => {doc:, pages:, chunks:}
    @next_id = 0
  end

  def migrate! = nil

  def find_document(filename)
    e = @docs.values.find { |x| x[:doc].filename == filename }
    e && summary(e)
  end

  def start_document(filename:, sha256:)
    @docs.delete_if { |_, e| e[:doc].filename == filename }
    id = (@next_id += 1)
    @docs[id] = { doc: Rag::Doc.new(id: id, filename: filename, sha256: sha256, status: "processing", error: nil), pages: [], chunks: [] }
    id
  end

  def finish_document(id, pages:, chunks:)
    e = @docs.fetch(id)
    e[:pages] = pages.dup
    e[:chunks] = chunks.dup
    e[:doc].status = "done"
    nil
  end

  def fail_document(id, message)
    e = @docs.fetch(id)
    e[:doc].status = "error"
    e[:doc].error = message
    nil
  end

  def documents = @docs.values.map { |e| summary(e) }.sort_by(&:filename)

  def pages(filename)
    e = @docs.values.find { |x| x[:doc].filename == filename }
    e ? e[:pages].sort_by(&:number) : []
  end

  def search(embedding, k)
    hits = @docs.values.flat_map do |e|
      e[:chunks].map do |c|
        Rag::Hit.new(filename: e[:doc].filename, page: c.page, text: c.text, distance: cosine_distance(embedding, c.embedding))
      end
    end
    hits.sort_by(&:distance).first(k)
  end

  private

  def summary(e)
    e[:doc].dup.tap { |d| d.page_count = e[:pages].size; d.chunk_count = e[:chunks].size }
  end

  def cosine_distance(a, b)
    dot = a.zip(b).sum { |x, y| x * y }
    1.0 - dot / (Math.sqrt(a.sum { |x| x * x }) * Math.sqrt(b.sum { |x| x * x }))
  end
end
