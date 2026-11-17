require "test_helper"
require "tmpdir"
require "stringio"

class UploadTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @dir = File.join(@root, "up")
    Dir.mkdir(@dir)
  end

  def teardown = FileUtils.remove_entry(@root)

  def save(name, body = "x", **opts) = Rag::Upload.save(filename: name, io: StringIO.new(body), dir: @dir, **opts)

  def assert_rejected(name, msg = "Chỉ nhận file .pdf và .docx.")
    e = assert_raises(Rag::Upload::Rejected) { save(name) }
    assert_equal msg, e.message
    assert_empty Dir.children(@dir)
  end

  def test_accepts_pdf_and_docx_and_lowercases_extension
    assert_equal "Report.docx", Rag::Upload.sanitize("Report.DOCX")
    assert_equal "a.pdf", Rag::Upload.sanitize("a.pdf")
  end

  def test_rejects_other_extensions
    ["a.exe", "a.txt", "noext", "a.pdf.exe", ".pdf", "a.pdf/"].each do |n|
      e = assert_raises(Rag::Upload::Rejected, n) { Rag::Upload.sanitize(n) }
      assert_equal "Chỉ nhận file .pdf và .docx.", e.message
    end
  end

  def test_hostile_names_raise_only_rejected_and_write_nothing
    ["\xff\xfe.txt".b.force_encoding("UTF-8"), nil, "", "...", "   .pdf", "../.pdf", "\0.pdf"].each do |n|
      assert_rejected(n)
    end
  end

  def test_invalid_utf8_bytes_are_scrubbed_in_an_accepted_name
    name = "a\xffb.pdf".dup.force_encoding("UTF-8")
    assert_equal "a_b.pdf", Rag::Upload.sanitize(name)
  end

  def test_traversal_names_land_inside_dir
    { "../../etc/passwd.pdf" => "passwd.pdf", "..\\..\\evil.pdf" => "evil.pdf",
      "/tmp/x.pdf" => "x.pdf", "a\0b.pdf" => "ab.pdf" }.each do |n, want|
      path = save(n)
      assert_equal want, File.basename(path)
      assert path.start_with?(File.realpath(@dir) + "/")
    end
    refute File.exist?(File.join(@dir, "..", "evil.pdf"))
  end

  def test_existing_symlink_is_replaced_not_followed
    target = File.join(@root, "target")
    File.write(target, "orig")
    File.symlink(target, File.join(@dir, "x.pdf"))
    save("x.pdf", "new")
    assert_equal "orig", File.read(target)
    refute File.symlink?(File.join(@dir, "x.pdf"))
    assert_equal "new", File.read(File.join(@dir, "x.pdf"))
  end

  def test_size_limit_exact_ok_and_one_over_rejected_without_leftovers
    save("a.pdf", "a" * 10, max_bytes: 10)
    File.delete(File.join(@dir, "a.pdf"))
    e = assert_raises(Rag::Upload::Rejected) { save("a.pdf", "a" * 11, max_bytes: 10) }
    assert_equal "File quá lớn (tối đa 30 MB).", e.message
    assert_empty Dir.children(@dir)
  end

  def test_failing_io_leaves_dir_empty
    io = Object.new
    def io.read(*) = (@n = (@n || 0) + 1) == 1 ? "abc" : raise(IOError, "boom")
    assert_raises(IOError) { Rag::Upload.save(filename: "a.pdf", io: io, dir: @dir, max_bytes: 10) }
    assert_empty Dir.children(@dir)
  end

  def test_directory_target_is_rejected
    Dir.mkdir(File.join(@dir, "d.pdf"))
    assert_raises(Rag::Upload::Rejected) { save("d.pdf") }
    assert_equal ["d.pdf"], Dir.children(@dir)
  end

  def test_same_name_replaces_content
    save("a.pdf", "one")
    save("a.pdf", "two")
    assert_equal "two", File.read(File.join(@dir, "a.pdf"))
  end

  def test_vietnamese_name_with_spaces_kept_and_nfd_becomes_nfc
    nfd = "Quy định nghỉ phép (2026).pdf".unicode_normalize(:nfd)
    refute_equal "Quy định nghỉ phép (2026).pdf", nfd
    assert_equal "Quy định nghỉ phép (2026).pdf", Rag::Upload.sanitize(nfd)
  end

  def test_other_special_characters_become_underscore
    assert_equal "a_b__c.pdf", Rag::Upload.sanitize("a<b>:c.pdf")
  end

  def test_long_stem_is_capped_and_extension_kept
    n = Rag::Upload.sanitize("#{"a" * 300}.PDF")
    assert_equal "#{"a" * 100}.pdf", n
  end
end
