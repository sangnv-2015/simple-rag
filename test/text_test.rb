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
end
