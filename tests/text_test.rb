require "test_helper"

class TextTest < Minitest::Test
  def test_clean_nfc_rstrip_keeps_column_runs
    assert_equal "Nghỉ phép    12\n\nHết", Rag::Text.clean("Nghỉ phép    12  \n\n\n\nHết\n\n")
  end

  def test_clean_normalizes_to_nfc
    assert_equal "Nghỉ".unicode_normalize(:nfc), Rag::Text.clean("Nghỉ".unicode_normalize(:nfd))
  end

  def test_squash_collapses_nbsp_newlines_and_unicode_form
    assert_equal "Nghỉ phép 12", Rag::Text.squash("  Nghỉ phép\n\t 12 ")
    assert_equal "a b", Rag::Text.squash("a  b")
    assert_equal "Nghỉ", Rag::Text.squash("Nghỉ".unicode_normalize(:nfd))
  end

  def test_comparable_drops_table_delimiter_rows_only
    assert_equal "| a | b | | 1 | 2 |", Rag::Text.comparable("| a | b |\n| --- | :---: |\n| 1 | 2 |")
    assert_equal "| a | -5 | | 1 |", Rag::Text.comparable("| a | -5 |\n| 1 |")
    assert_equal "a -- b", Rag::Text.comparable("a -- b")
    assert_equal "| a | - | | 1 | - |", Rag::Text.comparable("| a | - |\n|---|---|\n| 1 | - |")
  end

  def test_comparable_is_the_same_for_multiline_flat_and_crlf_tables
    multi = "| a | b |\n| :---: | ---: |\n| 1 | 2 |"
    want = "| a | b | | 1 | 2 |"
    [multi, multi.tr("\n", " "), multi.gsub("\n", "\r\n"), "| a | b |\n| 1 | 2 |"].each { |t| assert_equal want, Rag::Text.comparable(t) }
    assert_equal "", Rag::Text.comparable("|---|---|")
  end

  def test_locate_finds_comparable_quote_in_original_text
    md = "Giờ:\n| Ngày | Giờ |\n|---|---|\n| 1 | 7h00 |\nhết"
    r = Rag::Text.locate(md, Rag::Text.comparable("| Ngày | Giờ |\n|---|---|\n| 1 | 7h00 |"))
    assert_equal "| Ngày | Giờ |\n|---|---|\n| 1 | 7h00 |", md[r]
    assert_equal "Nghỉ\n  phép", "a Nghỉ\n  phép b"[Rag::Text.locate("a Nghỉ\n  phép b", "Nghỉ phép")]
    assert_nil Rag::Text.locate("abc", "xyz")
    assert_nil Rag::Text.locate("abc", "  ")
    assert_equal 0...2, Rag::Text.locate("a.b", "a.")
  end
end
