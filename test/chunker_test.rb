require "test_helper"

class ChunkerTest < Minitest::Test
  def split(text, max = 100) = Rag::Chunker.split(text, max_chars: max)

  def test_blank_input_gives_no_chunks
    assert_equal [], split(" \n\n ")
  end

  def test_heading_starts_new_chunk
    chunks = split("# A\nx\n\n# B\ny")
    assert_equal 2, chunks.size
    assert chunks[0].start_with?("# A")
    assert chunks[1].start_with?("# B")
  end

  def test_heading_only_chunk_merges_into_next
    chunks = split("# A\n## B\ntext")
    assert_equal 1, chunks.size
    assert_includes chunks[0], "text"
  end

  def test_paragraphs_pack_up_to_max_and_split_between_paragraphs
    paras = Array.new(6) { |i| "#{i}" * 40 }
    chunks = split(paras.join("\n\n"))
    assert chunks.size > 1
    assert chunks.all? { |c| c.size <= 100 }
    chunks.each { |c| assert c.split("\n\n").all? { |p| paras.include?(p) } }
  end

  def test_table_never_split_and_moves_whole_to_next_chunk
    table = Array.new(6) { |i| "|" + "r#{i}".ljust(57, "x") + "|" }.join("\n")
    chunks = split(("p" * 80) + "\n\n" + table)
    assert_equal 2, chunks.size
    assert_equal table, chunks[1]
  end

  def test_oversize_table_stays_one_chunk
    table = Array.new(5) { "|" + "c" * 58 + "|" }.join("\n")
    assert table.size >= 300
    assert_equal [table], split(table)
  end

  def test_oversize_paragraph_split_loses_nothing
    para = (1..45).map { |i| "Word#{i}." }.join(" ")
    para += " " + "z" * 150 # forces a hard cut
    chunks = split(para)
    assert chunks.size > 1
    assert chunks.all? { |c| c.size <= 100 }
    assert_equal para.gsub(/\s/, ""), chunks.join.gsub(/\s/, "")
  end

  def test_vietnamese_text_is_unchanged
    text = "Nhân viên được nghỉ phép năm 12 ngày.\nThời gian thử việc tối đa 60 ngày."
    assert_equal [text], split(text)
  end

  def test_plain_layout_text_splits_on_blank_lines
    a = "a" * 60
    b = "b" * 60
    assert_equal [a, b], split("#{a}\n\n#{b}")
  end
end
