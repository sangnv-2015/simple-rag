require "test_helper"
require "tmpdir"

class ExtractTest < Minitest::Test
  LINES = Array.new(150) { |i| "Quy định nghỉ phép năm số #{i} của công ty" }.join("\n")

  def test_split_pages_numbers_and_drops_trailing_empty
    pages = Rag::Extract.split_pages("Quy định nghỉ phép năm của công ty\fTrang hai có chữ đủ dài để đọc được\f")
    assert_equal [1, 2], pages.map(&:number)
    assert pages.all?(&:readable)
    assert pages.none?(&:fallback)
    assert pages.all? { |p| p.markdown.nil? }
  end

  def test_page_with_few_letters_is_unreadable
    pages = Rag::Extract.split_pages("  3  \n\f12345678901234567890123")
    assert_equal [false, false], pages.map(&:readable)
  end

  def test_nfd_input_is_composed_and_columns_kept
    nfd = "Nghỉ phép    12 ngày".unicode_normalize(:nfd)
    page = Rag::Extract.split_pages(nfd).first
    assert_equal "Nghỉ phép    12 ngày".unicode_normalize(:nfc), page.raw_text
  end

  def test_pdf_has_several_pages_with_vietnamese_text
    pages = Rag::Extract.pages(OfficeFixtures.pdf(LINES))
    assert_operator pages.size, :>=, 2
    assert_equal (1..pages.size).to_a, pages.map(&:number)
    assert_includes pages.first.raw_text, "Quy định nghỉ phép năm"
    assert pages.first.readable
  end

  def test_docx_is_converted_and_read
    pages = Rag::Extract.pages(OfficeFixtures.docx(LINES))
    assert_operator pages.size, :>=, 2
    assert_includes pages.first.raw_text, "Quy định nghỉ phép năm"
  end

  def test_garbage_pdf_raises_extract_error
    Dir.mktmpdir do |d|
      path = File.join(d, "x.pdf")
      File.binwrite(path, Random.bytes(500))
      assert_raises(Rag::Extract::Error) { Rag::Extract.pages(path) }
    end
  end

  def test_garbage_docx_raises_extract_error
    Dir.mktmpdir do |d|
      path = File.join(d, "x.docx")
      File.binwrite(path, Random.bytes(500))
      before = Dir.glob(File.join(Dir.tmpdir, "d*")).sort
      assert_raises(Rag::Extract::Error) { Rag::Extract.pages(path) }
      assert_equal before, Dir.glob(File.join(Dir.tmpdir, "d*")).sort
    end
  end

  def test_unsupported_extension_raises
    Dir.mktmpdir do |d|
      path = File.join(d, "x.txt")
      File.write(path, "hello")
      assert_raises(Rag::Extract::Error) { Rag::Extract.pages(path) }
    end
  end
end
