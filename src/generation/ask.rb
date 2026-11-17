module Rag
  Source = Struct.new(:n, :filename, :page, :quote)
  Answer = Struct.new(:text, :found, :sources)

  class Ask
    QUOTES_MARKER = "\n<<QUOTES>>\n"
    NOT_FOUND = "NOT_FOUND"
    # The model may not put the marker on its own line, so detect the bare token.
    TOKEN = QUOTES_MARKER.strip
    SOURCE_TAG = %r{\[/?S\d+\]}
    TOKEN_RE = Regexp.union(TOKEN, NOT_FOUND)

    # Forwards only the answer part of the stream: never the quotes block, never NOT_FOUND.
    class Filter
      def initialize(on_delta)
        @on_delta, @buf, @sent = on_delta, +"", 0
      end

      def push(delta)
        @buf << delta
        return if sentinel?
        limit = @buf.index(TOKEN_RE) || @buf.size - held_back
        # Whitespace right before a token is held too: the parser strips it from the answer.
        emit(@buf[0...limit].rstrip.size)
      end

      # Releases text held back as a possible marker that never completed.
      def finish
        emit(@buf.size) unless sentinel? || @buf.match?(TOKEN_RE)
      end

      private

      def emit(limit)
        return unless limit > @sent
        @on_delta.call(@buf[@sent...limit])
        @sent = limit
      end

      def sentinel?
        s = @buf.lstrip
        NOT_FOUND.start_with?(s) || s.start_with?(NOT_FOUND)
      end

      def held_back
        [TOKEN, NOT_FOUND].map { |t| (t.size - 1).downto(1).find { |n| @buf.end_with?(t[0, n]) } || 0 }.max
      end
    end

    def initialize(llm:, embedder:, store:, k: Rag::TOP_K)
      @llm, @retriever = llm, Retriever.new(embedder: embedder, store: store, k: k)
    end

    def call(question, &on_delta)
      return Answer.new("", false, []) if Text.squash(question).empty?
      hits = @retriever.call(question)
      return Answer.new("", false, []) if hits.empty?
      filter = on_delta && Filter.new(on_delta)
      reply = @llm.chat([{ role: "user", content: Prompts.answer(question, hits) }], &filter&.method(:push))
      filter&.finish
      parse(reply, hits)
    end

    private

    def parse(reply, hits)
      text, quotes = reply.split(TOKEN, 2)
      text = (text || "").then { |t| quotes ? t.rstrip : t }
      return Answer.new(text, false, []) if text.include?(NOT_FOUND)
      cited = text.scan(/\[S(\d+)\]/).flatten.map(&:to_i).uniq.select { |n| n.between?(1, hits.size) }
      quoted = {}
      quotes.to_s.each_line do |line|
        next unless (m = line.strip.match(/\A\[S(\d+)\]\s*(.+)\z/))
        quoted[m[1].to_i] ||= m[2].strip.sub(/\A(["“])(.*)(["”])\z/m, '\2')
      end
      sources = cited.map do |n|
        q = quoted[n] && Text.squash(quoted[n])
        ok = q && q.size >= Rag::MIN_QUOTE_CHARS && Text.squash(hits[n - 1].text).include?(q)
        Source.new(n, hits[n - 1].filename, hits[n - 1].page, ok ? q : nil)
      end
      Answer.new(text, !sources.empty?, sources)
    end
  end
end
