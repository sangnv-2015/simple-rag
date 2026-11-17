class FakeStore
  def initialize
    @docs = {} # id => {doc:, pages:, chunks:}
    @next_id = 0
    @next_chunk_id = 0
    @logs = []
  end

  def migrate! = nil

  def find_document(tenant_id:, title:, version:)
    e = @docs.values.find { |x| triple(x[:doc]) == [tenant_id, title, version] }
    e && summary(e)
  end

  def document(id, tenant_id: nil)
    e = @docs[id]
    e && (tenant_id.nil? || e[:doc].tenant_id == tenant_id) ? summary(e) : nil
  end

  def start_document(tenant_id:, title:, version:, valid_from:, valid_to:, filename:, path:, sha256:)
    @docs.delete_if { |_, e| triple(e[:doc]) == [tenant_id, title, version] }
    id = (@next_id += 1)
    doc = Rag::Doc.new(id: id, filename: filename, sha256: sha256, status: "processing", error: nil, tenant_id: tenant_id,
                       title: title, version: version, valid_from: valid_from, valid_to: valid_to, path: path)
    @docs[id] = { doc: doc, pages: [], chunks: [] }
    id
  end

  def finish_document(id, pages:, chunks:)
    e = @docs.fetch(id)
    e[:pages] = pages.map { |p| p.dup.tap { |q| q.raw_text = nul(q.raw_text); q.markdown = nul(q.markdown) } }
    e[:chunks] = chunks.map { |c| c.dup.tap { |d| d.text = nul(d.text); d.id = (@next_chunk_id += 1) } }
    me = e[:doc]
    me.status = "done"
    siblings = @docs.values.map { |x| x[:doc] }.select { |d| d.tenant_id == me.tenant_id && d.title == me.title && d.status == "done" }
    if siblings.any? { |d| d.version > me.version }
      me.status = "expired"
    else
      siblings.select { |d| d.version < me.version }.each do |d|
        d.status = "expired"
        d.valid_to = [d.valid_to, me.valid_from].min
      end
    end
    nil
  end

  def fail_document(id, message)
    e = @docs[id] or return
    e[:doc].status = "error"
    e[:doc].error = message
    nil
  end

  def documents(tenant_id: nil)
    @docs.values.map { |e| summary(e) }.select { |d| tenant_id.nil? || d.tenant_id == tenant_id }
         .sort_by { |d| [d.title, -d.version, d.id] }
  end

  def delete_document(id, tenant_id:)
    e = @docs[id]
    return nil unless e && e[:doc].tenant_id == tenant_id
    @docs.delete(id)
    summary(e)
  end

  def pages(document_id)
    e = @docs[document_id]
    e ? e[:pages].sort_by(&:number) : []
  end

  def chunks(document_id)
    e = @docs[document_id]
    e ? e[:chunks].sort_by { |c| [c.position, c.id] }.map { |c| c.dup.tap { |d| d.embedding = nil } } : []
  end

  def search(embedding, k, tenant_id:, document_ids: [], on: Date.today)
    hits = @docs.values.flat_map do |e|
      d = e[:doc]
      next [] unless d.tenant_id == tenant_id && d.current?(on) && (document_ids.empty? || document_ids.include?(d.id))
      e[:chunks].map do |c|
        Rag::Hit.new(filename: d.filename, page: c.page, text: c.text, distance: cosine_distance(embedding, c.embedding),
                     chunk_id: c.id, document_id: d.id, title: d.title, version: d.version)
      end
    end
    hits.sort_by(&:distance).first(k)
  end

  def log_query(tenant_id:, question:, standalone:, document_ids:, retrieved_chunk_ids:, scores:, status:, answer:,
                cited_chunk_ids:, source:)
    @logs << { "tenant_id" => tenant_id, "question" => question, "standalone" => standalone, "document_ids" => document_ids,
               "retrieved_chunk_ids" => retrieved_chunk_ids, "scores" => scores, "status" => status, "answer" => answer,
               "cited_chunk_ids" => cited_chunk_ids, "source" => source }
    nil
  end

  def query_logs(limit: 100) = @logs.reverse.first(limit)

  private

  def triple(d) = [d.tenant_id, d.title, d.version]

  def nul(s) = s&.delete("\u0000")

  def summary(e)
    e[:doc].dup.tap { |d| d.page_count = e[:pages].size; d.chunk_count = e[:chunks].size }
  end

  def cosine_distance(a, b)
    dot = a.zip(b).sum { |x, y| x * y }
    1.0 - dot / (Math.sqrt(a.sum { |x| x * x }) * Math.sqrt(b.sum { |x| x * x }))
  end
end
