require "test_helper"
require "tmpdir"

class ExtractTest < Minitest::Test
  LINES = Array.new(150) { |i| "Quy định nghỉ phép năm số #{i} của công ty" }.join("\n")

  # Failed conversions log to $stderr for the operator: keep test output clean.
  def setup = ($real_stderr, $stderr = $stderr, StringIO.new)
  def teardown = ($stderr = $real_stderr)

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

  def test_pdftotext_is_bounded_by_the_page_cap
    st = Struct.new(:success?, :exitstatus).new(true, 0)
    seen = nil
    real = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) { |*cmd| seen = cmd; ["", "", st] }
    begin
      Dir.mktmpdir do |d|
        path = File.join(d, "x.pdf")
        File.write(path, "x")
        Rag::Extract.pages(path)
      end
    ensure
      Open3.define_singleton_method(:capture3, real)
    end
    assert_equal (Rag::MAX_PAGES + 1).to_s, seen[seen.index("-l") + 1]
  end

  def test_failed_command_logs_to_stderr_but_user_message_has_no_details
    Dir.mktmpdir do |d|
      path = File.join(d, "x.pdf")
      File.binwrite(path, Random.bytes(500))
      err = assert_raises(Rag::Extract::Error) { Rag::Extract.pages(path) }
      logged = $stderr.string
      assert_equal "Không đọc được tệp x.pdf.", err.message
      assert_match(/pdftotext.*exit \d+/, logged)
      assert_operator logged.size, :<=, 400
    end
  end

  def rag_tmpdirs = Dir.glob(File.join(Dir.tmpdir, "rag-docx*")).sort

  def test_garbage_docx_raises_extract_error
    Dir.mktmpdir do |d|
      path = File.join(d, "x.docx")
      File.binwrite(path, Random.bytes(500))
      assert_raises(Rag::Extract::Error) { Rag::Extract.pages(path) }
    end
  end

  # soffice imports PK+random bytes as a text "document" (no error), so only cleanup is asserted.
  def test_pk_prefixed_garbage_docx_leaves_no_temp_dir
    Dir.mktmpdir do |d|
      path = File.join(d, "x.docx")
      File.binwrite(path, "PK" + Random.bytes(500))
      before = rag_tmpdirs
      begin
        Rag::Extract.pages(path)
      rescue Rag::Extract::Error
        nil
      end
      assert_equal before, rag_tmpdirs
    end
  end

  def test_successful_docx_leaves_no_temp_dir
    docx = OfficeFixtures.docx(LINES)
    before = rag_tmpdirs
    Rag::Extract.pages(docx)
    assert_equal before, rag_tmpdirs
  end

  def test_missing_files_raise_extract_error
    Dir.mktmpdir do |d|
      %w[x.pdf x.docx].each do |name|
        assert_raises(Rag::Extract::Error) { Rag::Extract.pages(File.join(d, name)) }
      end
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
