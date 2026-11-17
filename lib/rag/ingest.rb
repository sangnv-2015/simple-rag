require "digest"

module Rag
  Report = Struct.new(:ok, :skipped, :failed, :empty_dir) do
    def failed? = !failed.empty?

    def summary
      return "Không có file .pdf/.docx nào trong #{empty_dir}" if empty_dir
      lines = []
      lines << "OK: #{ok.join(", ")}" unless ok.empty?
      lines << "Bỏ qua (không đổi): #{skipped.join(", ")}" unless skipped.empty?
      failed.each { |f, m| lines << "Lỗi: #{f} — #{m}" }
      lines.join("\n")
    end
  end

  class Ingest
    EXTENSIONS = %w[.pdf .docx].freeze
    UNKNOWN_ERROR = "Lỗi không xác định khi xử lý file.".freeze

    def initialize(llm:, embedder:, store:, extractor: Rag::Extract)
      @restructurer = Restructurer.new(llm: llm)
      @embedder = embedder
      @store = store
      @extractor = extractor
    end

    def call(path)
      report = Report.new([], [], [])
      files = files_for(path, report)
      files.each { |f| ingest_file(f, report) }
      report
    end

    private

    def files_for(path, report)
      return [path] unless File.directory?(path)
      files = Dir.children(path).select { |n| EXTENSIONS.include?(File.extname(n).downcase) }.sort
      report.empty_dir = path if files.empty?
      files.map { |n| File.join(path, n) }
    end

    def ingest_file(path, report)
      name = Text.nfc(File.basename(path))
      id = nil
      begin
        raise Error, "Chỉ nhận file .pdf và .docx." unless EXTENSIONS.include?(File.extname(name).downcase)
        sha = Digest::SHA256.file(path).hexdigest
        existing = @store.find_document(name)
        return report.skipped << name if existing && existing.sha256 == sha && existing.status == "done"
        id = @store.start_document(filename: name, sha256: sha)
        pages, chunks = process(path)
        @store.finish_document(id, pages: pages, chunks: chunks)
        report.ok << name
      rescue StandardError => e
        message = e.is_a?(Error) ? e.message : UNKNOWN_ERROR
        warn "ingest #{name}: #{e.class}: #{e.message}" unless e.is_a?(Error)
        record_failure(id, message)
        report.failed << [name, message]
      end
    end

    def process(path)
      pages = @extractor.pages(path)
      readable = pages.select(&:readable)
      raise Error, "file scan, không đọc được" if readable.empty?
      readable.each do |page|
        r = @restructurer.call(page.raw_text)
        page.markdown = r.markdown
        page.fallback = r.fallback
      end
      pieces = readable.flat_map do |page|
        Chunker.split(page.fallback ? page.raw_text : page.markdown).each_with_index.map { |t, i| [page, i, t] }
      end
      vectors = @embedder.embed_passages(pieces.map(&:last))
      chunks = pieces.zip(vectors).map { |(page, i, t), v| Chunk.new(page: page.number, position: i, text: t, embedding: v) }
      [pages, chunks]
    end

    # A dead database must not abort the rest of the batch.
    def record_failure(id, message)
      @store.fail_document(id, message) if id
    rescue StandardError => e
      warn "ingest: could not record failure: #{e.class}: #{e.message}"
    end
  end
end
