module Rag
  module Text
    def self.nfc(s) = s.unicode_normalize(:nfc)

    # Inner runs of spaces are kept: they carry table columns.
    def self.clean(raw)
      nfc(raw).gsub(/[ \t]+$/, "").gsub(/\n{3,}/, "\n\n").gsub(/\A\n+|\n+\z/, "")
    end

    def self.squash(s) = nfc(s).gsub(/\p{Space}+/, " ").strip

    # Markdown table delimiter run (|---|:-:|): layout only, models routinely omit it when quoting a table.
    # Matched after squash so multi-line, CRLF and flattened one-line tables all look alike.
    # shortcut: needs 3+ dashes (a lone "-" is a data cell) and a leading pipe, as the DeepSeek restructurer writes them.
    # A data cell of 3+ dashes ("---" as N/A) is also dropped, so a quote omitting it verifies; none in the corpus today
    # (checked 2026-11-17). Upgrade to stripping only the row right after a header if such cells appear.
    TABLE_RULE = / ?\|(?: ?:?-{3,}:? ?\|)+/

    # Form used to compare a quote with a chunk: squash minus table delimiter runs.
    def self.comparable(s) = squash(s).gsub(TABLE_RULE, "").strip

    # Range of a comparable-form quote inside the original text (whitespace and table rules may differ), or nil.
    def self.locate(text, quote)
      words = comparable(quote.to_s).split(" ")
      return nil if words.empty?
      gap = /(?:\s+|\s*\|(?:\s*:?-{3,}:?\s*\|)+\s*)+/.source
      m = nfc(text.to_s).match(Regexp.new(words.map { |w| Regexp.escape(w) }.join(gap)))
      m && (m.begin(0)...m.end(0))
    end
  end
end
