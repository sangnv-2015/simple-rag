module Rag
  Restructured = Struct.new(:markdown, :fallback)

  class Restructurer
    NUMBER = /\d+(?:[.,]\d+)*/

    PROMPT = <<~TXT
      Below is the text of one page of a document, extracted with the layout kept.
      Aligned columns separated by wide gaps of spaces on the same line are table columns.
      Rewrite the page as clean markdown. Rules:
      - Output only the markdown for this page, nothing else.
      - Keep headings and lists.
      - Rebuild tables as markdown tables.
      - Do not summarise, translate, add or remove anything.
      - Copy every number exactly as written.
      - Keep headers and footers as they are.

      Page text:
      ---
      %s
    TXT

    def self.numbers_preserved?(raw, markdown)
      have = Text.squash(markdown).scan(NUMBER)
      Text.squash(raw).scan(NUMBER).all? { |t| have.include?(t) }
    end

    def initialize(llm:)
      @llm = llm
    end

    def call(raw_text)
      reply = @llm.chat([{ role: "user", content: format(PROMPT, raw_text) }])
      markdown = reply.strip.sub(/\A```(?:markdown)?[ \t]*\n(.*?)\n?```\z/m, '\1').strip
      Restructured.new(markdown, markdown.empty? || !self.class.numbers_preserved?(raw_text, markdown))
    end
  end
end
