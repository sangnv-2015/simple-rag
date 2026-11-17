require "digest"

module Rag
  Report = Struct.new(:ok, :skipped, :failed, :empty_dir, :no_metadata) do
    def failed? = !failed.empty?

    def summary
      return "Không có file .pdf/.docx nào trong #{empty_dir}" if empty_dir
      lines = []
      lines << "OK: #{ok.join(", ")}" unless ok.empty?
      lines << "Bỏ qua (không đổi): #{skipped.join(", ")}" unless skipped.empty?
      lines << "Bỏ qua (thiếu metadata): #{no_metadata.join(", ")}" unless no_metadata.empty?
      failed.each { |f, m| lines << "Lỗi: #{f} — #{m}" }
      lines.join("\n")
    end
  end

  Prepared = Struct.new(:id, :skipped, :filename)

  class Ingest
    EXTENSIONS = %w[.pdf .docx].freeze
    UNKNOWN_ERROR = "Lỗi không xác định khi xử lý file.".freeze

    def initialize(llm:, embedder:, store:, extractor: Rag::Extract, chunking: Rag::CHUNKING)
      @restructurer = Restructurer.new(llm: llm)
      @embedder = embedder
      @store = store
      @extractor = extractor
      @chunking = chunking
    end

    # metadata: a Meta for a single file, or { nfc basename => Meta }.
    def call(path, metadata)
      report = Report.new([], [], [], nil, [])
      files_for(path, report).each { |f| ingest_file(f, metadata, report) }
      report
    end

    def prepare(path, meta, filename: nil)
      name = Text.nfc(filename || File.basename(path))
      raise Error, "Chỉ nhận file .pdf và .docx." unless EXTENSIONS.include?(File.extname(name).downcase)
      sha = Digest::SHA256.file(path).hexdigest
      existing = @store.find_document(tenant_id: meta.tenant_id, title: meta.title, version: meta.version)
      if existing && existing.sha256 == sha && %w[done expired].include?(existing.status)
        # Same file, maybe new dates: keep the data, store the dates the caller gave (not on expired: its valid_to was trimmed by the newer version).
        @store.update_validity(existing.id, valid_from: meta.valid_from, valid_to: meta.valid_to) unless existing.status == "expired" || [existing.valid_from, existing.valid_to] == [meta.valid_from, meta.valid_to]
        return Prepared.new(existing.id, true, name)
      end
      id = @store.start_document(**meta.to_h, filename: name, path: path, sha256: sha)
      Prepared.new(id, false, name)
    end

    # Returns nil on success, or the failure message (also recorded on the document).
    def run(id, path)
      pages, chunks = process(path)
      @store.finish_document(id, pages: pages, chunks: chunks)
      nil
    rescue StandardError => e
      message = e.is_a?(Error) ? e.message : UNKNOWN_ERROR
      warn "ingest #{File.basename(path)}: #{e.class}: #{e.message}" unless e.is_a?(Error)
      record_failure(id, message)
      message
    end

    private

    def files_for(path, report)
      return [path] unless File.directory?(path)
      files = Dir.children(path).select { |n| EXTENSIONS.include?(File.extname(n).downcase) }.sort
      report.empty_dir = path if files.empty?
      files.map { |n| File.join(path, n) }
    end

    def ingest_file(path, metadata, report)
      name = Text.nfc(File.basename(path))
      meta = metadata.is_a?(Hash) ? metadata[name] : metadata
      return report.no_metadata << name unless meta
      begin
        prep = prepare(path, meta)
      rescue StandardError => e
        message = e.is_a?(Error) ? e.message : UNKNOWN_ERROR
        warn "ingest #{name}: #{e.class}: #{e.message}" unless e.is_a?(Error)
        return report.failed << [name, message]
      end
      return report.skipped << name if prep.skipped
      message = run(prep.id, path)
      message ? report.failed << [name, message] : report.ok << name
    end

    def process(path)
      pages = @extractor.pages(path)
      raise Error, "Tài liệu quá dài (tối đa #{MAX_PAGES} trang)." if pages.size > MAX_PAGES
      readable = pages.select(&:readable)
      raise Error, "file scan, không đọc được" if readable.empty?
      readable.each do |page|
        if page.raw_text.size > MAX_PAGE_CHARS # too big to send: keep the raw text
          page.fallback = true
          next
        end
        r = @restructurer.call(page.raw_text)
        page.markdown = r.markdown
        page.fallback = r.fallback
      end
      pieces = readable.flat_map do |page|
        chunk(page.fallback ? page.raw_text : page.markdown).each_with_index.map { |t, i| [page, i, t] }
      end
      vectors = @embedder.embed_passages(pieces.map(&:last))
      chunks = pieces.zip(vectors).map { |(page, i, t), v| Chunk.new(page: page.number, position: i, text: t, embedding: v) }
      [pages, chunks]
    end

    def chunk(text)
      return Chunker.split(text) if @chunking == "structure"
      SemanticChunker.split(text, embed: ->(t) { @embedder.embed_passages(t) })
    end

    # A dead database must not abort the rest of the batch.
    def record_failure(id, message)
      @store.fail_document(id, message) if id
    rescue StandardError => e
      warn "ingest: could not record failure: #{e.class}: #{e.message}"
    end
  end
end
