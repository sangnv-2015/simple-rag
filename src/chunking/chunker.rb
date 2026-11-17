module Rag
  module Chunker
    SEP = "\n\n"

    def self.split(text, max_chars: Rag::MAX_CHUNK_CHARS)
      chunks = []
      cur = +""
      only_headings = true
      blocks(text).each do |kind, body|
        pieces = kind == :para ? pieces(body, max_chars).map(&:strip).reject(&:empty?) : [body]
        pieces.each do |piece|
          # Headings always merge into what follows, so a heading-only chunk may exceed max_chars.
          if !cur.empty? && !only_headings && (kind == :heading || cur.size + SEP.size + piece.size > max_chars)
            chunks << cur
            cur = +""
            only_headings = true
          end
          cur << SEP unless cur.empty?
          cur << piece
          only_headings &&= kind == :heading
        end
      end
      chunks << cur
      chunks.reject { |c| c.strip.empty? }
    end

    # Returns [[:heading|:table|:para, text], ...]
    def self.blocks(text)
      out = []
      para = []
      table = []
      flush = lambda do
        out << [:para, para.join("\n")] unless para.empty?
        out << [:table, table.join("\n")] unless table.empty?
        para = []
        table = []
      end
      text.each_line(chomp: true) do |line|
        if line.strip.empty?
          flush.call
        elsif line.start_with?("|")
          out << [:para, para.join("\n")] unless para.empty?
          para = []
          table << line
        elsif line.start_with?("#")
          flush.call
          out << [:heading, line]
        else
          out << [:table, table.join("\n")] unless table.empty?
          table = []
          para << line
        end
      end
      flush.call
      out
    end

    # Split an oversize paragraph on line ends, then sentence ends, then hard-cut.
    # Pieces keep their trailing whitespace; the caller strips the final result.
    def self.pieces(text, max)
      return [text] if text.size <= max

      units = text.lines
      units = text.split(/(?<=\. )/) if units.size == 1
      units = text.scan(/.{1,#{max}}/m) if units.size == 1
      packed = [+""]
      units.flat_map { |u| pieces(u, max) }.each do |u|
        packed << +"" if packed.last.size + u.size > max
        packed.last << u
      end
      packed
    end
  end
end
