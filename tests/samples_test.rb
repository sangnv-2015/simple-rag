require "test_helper"
require "yaml"

class SamplesTest < Minitest::Test
  MANIFEST = YAML.safe_load_file("data/samples/manifest.yml", symbolize_names: true)
  QUESTIONS = YAML.safe_load_file("evaluation/questions.yml", symbolize_names: true)

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
    refute others.first[:out].start_with?("data/raw/")
    assert preloaded.all? { |m| m[:out].start_with?("data/raw/") }
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

  def test_every_manifest_entry_has_valid_metadata
    metas = Rag::Manifest.load
    assert_equal MANIFEST.map { |m| Rag::Text.nfc(File.basename(m[:out])) }.sort, metas.keys.sort
  end

  def leave = MANIFEST.select { |m| m[:title] == "Quy chế nghỉ phép" }.sort_by { |m| m[:version] }

  def test_nus_leave_policy_has_expired_v1_and_current_v2
    v1, v2 = leave
    assert_equal [1, 2], [v1[:version], v2[:version]]
    assert_equal %w[nus nus], [v1[:tenant], v2[:tenant]]
    assert_operator Date.parse(v1[:valid_to]), :<, Date.new(2026, 1, 1)
    assert_includes Date.parse(v2[:valid_from])..Date.parse(v2[:valid_to]), Date.today
  end

  def test_acme_document_exists_with_a_nus_namesake_title
    acme = MANIFEST.find { |m| m[:tenant] == "acme" }
    refute_nil acme
    assert MANIFEST.any? { |m| m[:tenant] == "nus" && m[:title] == acme[:title] }
    assert_equal "acme-quy-dinh-lam-viec-tu-xa.docx", File.basename(acme[:out])
  end

  def test_v1_differs_from_v2_on_every_figure_the_questions_ask_about
    v1, v2 = leave
    pages = ->(m) { Rag::Extract.pages(m[:out]).map { |pg| Rag::Text.squash(pg.raw_text).unicode_normalize(:nfc) } }
    ["tối đa 5 ngày", "16 ngày", "3 ngày làm việc", "9 giờ sáng"].each do |phrase|
      assert pages.(v2).any? { |t| t.include?(phrase) }, "v2 lacks #{phrase}"
      refute pages.(v1).any? { |t| t.include?(phrase) }, "v1 has #{phrase}"
    end
    assert pages.(v2).any? { |t| t.include?("Phiên bản 2") }
    assert pages.(v1).any? { |t| t.include?("Phiên bản 1") }
  end

  def test_tc_tags_cover_tc1_tc3_tc4_tc5_tc6_tc7_and_tenants_are_configured
    tags = QUESTIONS.flat_map { |q| q[:tc].to_a }
    assert_empty %w[TC1 TC3 TC4 TC5 TC6 TC7] - tags
    assert_equal ["travel-expense-policy.pdf"], QUESTIONS.find { |q| q[:tc].to_a.include?("TC6") }[:select]
    tenants = Rag::TENANT_SETTINGS.fetch("tenants")
    QUESTIONS.each { |q| assert_includes tenants, q.fetch(:tenant, "nus"), q[:question] }
  end

  def test_tc5_twin_phrases_are_absent_from_the_other_tenants_file
    text = ->(f) { text_of(MANIFEST.find { |m| File.basename(m[:out]) == f }[:out]) }
    refute_includes text.("acme-quy-dinh-lam-viec-tu-xa.docx"), "tối đa 2 ngày"
    refute_includes text.("quy-dinh-lam-viec-tu-xa.docx"), "tối đa 4 ngày"
  end
end
