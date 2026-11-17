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

  def test_numbers_ignore_layout_spaces_and_nfd
    raw = "Nghỉ phép      12\n   ngày".unicode_normalize(:nfd)
    assert keep?(raw, "| Nghỉ phép | 12 ngày |")
    assert keep?("Nghỉ 12", "Nghỉ phép 12".unicode_normalize(:nfd))
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
end
