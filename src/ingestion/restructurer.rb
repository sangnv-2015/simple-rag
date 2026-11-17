module Rag
  Restructured = Struct.new(:markdown, :fallback)

  class Restructurer
    NUMBER = /\d+(?:[.,]\d+)*/

    def self.numbers_preserved?(raw, markdown)
      # shortcut: token bag, so swapped values (A 12, B 13 -> A 13, B 12) pass; upgrade to ordered comparison if that matters.
      have = Text.squash(markdown).scan(NUMBER).tally
      Text.squash(raw).scan(NUMBER).tally.all? { |t, n| have.fetch(t, 0) >= n }
    end

    def initialize(llm:)
      @llm = llm
    end

    def unfence(text)
      m = text.match(/\A```(?:markdown|md)?[ \t]*\n(.*?)\n?```\z/mi)
      m && m[1].lines.none? { |l| l.start_with?("```") } ? m[1].strip : text
    end

    def call(raw_text)
      reply = @llm.chat([{ role: "user", content: Prompts.restructure(raw_text) }])
      markdown = unfence(reply.strip)
      Restructured.new(markdown, markdown.empty? || !self.class.numbers_preserved?(raw_text, markdown))
    end
  end
end
