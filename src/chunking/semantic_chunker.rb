module Rag
  module SemanticChunker
    # Sentences, whole tables, and headings prefixed onto the unit that follows them.
    def self.units(text)
      out = []
      heading = []
      table = []
      flush_table = lambda do
        next if table.empty?
        out << (heading + [table.join("\n")]).join("\n")
        heading = []
        table = []
      end
      Text.nfc(text).each_line(chomp: true) do |line|
        line = line.strip
        if line.start_with?("|")
          table << line
          next
        end
        flush_table.call
        if line.empty?
          next
        elsif line.start_with?("#")
          heading << line
        else
          line.split(/(?<=[.!?])\s+/).each do |s|
            out << (heading + [s]).join("\n")
            heading = []
          end
        end
      end
      flush_table.call
      out << heading.join("\n") unless heading.empty?
      out
    end

    def self.split(text, embed:, max_chars: MAX_CHUNK_CHARS, percentile: SEMANTIC_PERCENTILE, floor: SEMANTIC_FLOOR, min_units: SEMANTIC_MIN_UNITS)
      us = units(text)
      return [] if us.empty?
      vectors = embed.call(us)
      sims = us.each_cons(2).with_index.map { |_, i| cosine(vectors[i], vectors[i + 1]) }
      breakpoint = sims.size >= min_units - 1 ? percentile_of(sims, percentile) : floor
      chunks = []
      cur = nil
      us.each_with_index do |u, i|
        if u.size > max_chars
          chunks << cur if cur
          cur = nil
          chunks.concat(Chunker.pieces(u, max_chars).map(&:strip).reject(&:empty?))
          next
        end
        if cur.nil?
          cur = u
        elsif sims[i - 1] < breakpoint || cur.size + sep(cur, u).size + u.size > max_chars
          chunks << cur
          cur = u
        else
          cur = cur + sep(cur, u) + u
        end
      end
      chunks << cur if cur
      chunks
    end

    def self.sep(a, b) = block?(a) || block?(b) ? Chunker::SEP : "\n"

    def self.block?(u) = u.start_with?("#", "|")

    def self.cosine(a, b)
      na = Math.sqrt(a.sum { |x| x * x })
      nb = Math.sqrt(b.sum { |x| x * x })
      return 0.0 if na.zero? || nb.zero?
      a.zip(b).sum { |x, y| x * y } / (na * nb)
    end

    # Linear interpolation between closest ranks.
    def self.percentile_of(values, p)
      s = values.sort
      rank = (p / 100.0) * (s.size - 1)
      lo = rank.floor
      s[lo] + (s[[lo + 1, s.size - 1].min] - s[lo]) * (rank - lo)
    end
  end
end
