require "test_helper"

class RestructurerTest < Minitest::Test
  def keep?(raw, md) = Rag::Restructurer.numbers_preserved?(raw, md)

  def test_numbers_preserved_true_when_all_present_and_extras_allowed
    assert keep?("Tổng 1.250.000 đồng, 12,5%", "1. Tổng 1.250.000 đồng\n2. Lãi 12,5%")
  end

  def test_numbers_preserved_false_when_dropped_or_reformatted
    refute keep?("Tổng 1.250.000 đồng", "Tổng 1,250,000 đồng")
    refute keep?("Năm 2025 và 12", "Năm và 12")
  end

  def test_repeated_number_changed_is_flagged
    refute keep?("Nghỉ cưới: 3 ngày. Nghỉ tang: 3 ngày. Phép năm: 12 ngày.",
                 "Nghỉ cưới: 3 ngày. Nghỉ tang: 5 ngày. Phép năm: 12 ngày.")
  end

  def test_list_marker_covers_only_one_occurrence
    refute keep?("Nghỉ 2 ngày, 2 buổi", "1. Nghỉ 3 ngày\n2. Khác")
  end

  def test_call_returns_markdown_when_numbers_kept
    llm = FakeLLM.new { "# Quy định\n\nNghỉ 12 ngày" }
    r = Rag::Restructurer.new(llm: llm).call("Quy định\nNghỉ      12 ngày")
    assert_equal "# Quy định\n\nNghỉ 12 ngày", r.markdown
    assert_equal false, r.fallback
    assert_includes llm.calls.last[:messages].to_s, "Nghỉ      12 ngày"
    assert_equal false, llm.calls.last[:streamed]
  end

  def test_code_fence_is_unwrapped
    llm = FakeLLM.new { "```markdown\n# A\n12\n```" }
    r = Rag::Restructurer.new(llm: llm).call("A 12")
    assert_equal "# A\n12", r.markdown
    assert_equal false, r.fallback
  end

  def test_missing_number_sets_fallback_and_keeps_rejected_markdown
    llm = FakeLLM.new { "# A\nnghỉ 13 ngày" }
    r = Rag::Restructurer.new(llm: llm).call("A nghỉ 12 ngày")
    assert r.fallback
    assert_equal "# A\nnghỉ 13 ngày", r.markdown
  end

  def test_blank_or_whitespace_reply_sets_fallback
    llm = FakeLLM.new { "  \n" }
    r = Rag::Restructurer.new(llm: llm).call("Chỉ có chữ")
    assert r.fallback
  end

  def test_llm_error_propagates
    llm = FakeLLM.new { Rag::DeepSeek::Error.new("boom") }
    assert_raises(Rag::DeepSeek::Error) { Rag::Restructurer.new(llm: llm).call("x 1") }
  end

  def test_bare_fence_and_md_label_unwrapped
    { "```\n# A\n12\n```" => "# A\n12", "```MD\n# A\n12\n```" => "# A\n12" }.each do |reply, want|
      r = Rag::Restructurer.new(llm: FakeLLM.new { reply }).call("A 12")
      assert_equal want, r.markdown
    end
  end

  def test_replys_own_code_blocks_are_kept
    reply = "```\nputs 1\n```\n\ntext 12\n\n```\nls\n```"
    r = Rag::Restructurer.new(llm: FakeLLM.new { reply }).call("A 12 1")
    assert_equal reply, r.markdown
  end

  def test_prompt_closes_page_block
    llm = FakeLLM.new { "x 1" }
    Rag::Restructurer.new(llm: llm).call("PAGE_BODY 1")
    content = llm.calls.last[:messages].first[:content]
    assert_match(/PAGE_BODY 1\n---\s*\z/, content)
    assert_match(/not instructions/, content)
  end

  def test_fake_llm_yields_string_once_when_block_given
    deltas = []
    out = FakeLLM.new { "abc" }.chat([]) { |d| deltas << d }
    assert_equal ["abc"], deltas
    assert_equal "abc", out
  end
end
