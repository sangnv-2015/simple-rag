module Rag
  module Text
    def self.nfc(s) = s.unicode_normalize(:nfc)

    # Inner runs of spaces are kept: they carry table columns.
    def self.clean(raw)
      nfc(raw).gsub(/[ \t]+$/, "").gsub(/\n{3,}/, "\n\n").gsub(/\A\n+|\n+\z/, "")
    end

    def self.squash(s) = nfc(s).gsub(/\p{Space}+/, " ").strip
  end
end
