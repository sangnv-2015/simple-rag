require "test_helper"
require "yaml"

class SamplesTest < Minitest::Test
  MANIFEST = YAML.safe_load_file("samples/manifest.yml", symbolize_names: true)
  QUESTIONS = YAML.safe_load_file("samples/questions.yml", symbolize_names: true)

  def preloaded = MANIFEST.select { |m| m[:preload] }

  def text_of(path)
    Rag::Text.squash(Rag::Extract.pages(path).map(&:raw_text).join(" ")).unicode_normalize(:nfc)
  end

  def test_manifest_covers_spec_mix
    assert_operator preloaded.count { |m| m[:lang] == "vi" }, :>=, 2
    assert_operator preloaded.count { |m| m[:lang] == "en" }, :>=, 1
    assert_equal %w[.docx .pdf], preloaded.map { |m| File.extname(m[:out]) }.uniq.sort
    others = MANIFEST.reject { |m| m[:preload] }
    assert_equal 1, others.size
    refute others.first[:out].start_with?("documents/")
    assert preloaded.all? { |m| m[:out].start_with?("documents/") }
  end

  def test_every_sample_has_three_readable_pages
    MANIFEST.each do |m|
      pages = Rag::Extract.pages(m[:out])
      assert_operator pages.size, :>=, 3, m[:out]
      assert pages.all?(&:readable), m[:out]
    end
  end

  def test_every_answerable_question_phrase_is_on_one_page_of_its_file
    QUESTIONS.select { |q| q[:answerable] }.each do |q|
      path = MANIFEST.find { |m| File.basename(m[:out]) == q[:file] }&.fetch(:out)
      refute_nil path, q[:question]
      phrase = Rag::Text.squash(q[:contains]).unicode_normalize(:nfc)
      assert Rag::Extract.pages(path).any? { |pg| Rag::Text.squash(pg.raw_text).unicode_normalize(:nfc).include?(phrase) },
             "#{q[:question]} -> #{q[:contains]}"
    end
  end

  def test_unanswerable_probe_terms_are_absent_from_every_sample
    all = MANIFEST.map { |m| text_of(m[:out]).downcase }.join(" ")
    unanswerable = QUESTIONS.reject { |q| q[:answerable] }
    unanswerable.each do |q|
      refute_empty q[:probe].to_a, q[:question]
      q[:probe].each { |t| refute all.include?(t.unicode_normalize(:nfc).downcase), "#{t} found (#{q[:question]})" }
    end
  end

  def test_question_set_has_required_mix
    pre = QUESTIONS.select { |q| q[:answerable] && !q[:after_upload] }
    assert_operator pre.size, :>=, 8
    assert_operator QUESTIONS.count { |q| !q[:answerable] }, :>=, 2
    flagged = QUESTIONS.select { |q| q[:after_upload] }
    assert_equal 1, flagged.size
    assert_equal "chinh-sach-hoan-tien.docx", flagged.first[:file]
  end
end
