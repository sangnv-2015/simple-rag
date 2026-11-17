require "test_helper"
require "tmpdir"

class SettingsTest < Minitest::Test
  def test_yaml_settings_give_the_documented_constants
    assert_equal ["Xenova/multilingual-e5-small", 384, 6, 1000, 20, 10, 200, 20_000, 30 * 1024 * 1024],
                 [Rag::EMBED_MODEL, Rag::EMBED_DIM, Rag::TOP_K, Rag::MAX_CHUNK_CHARS, Rag::MIN_LETTERS,
                  Rag::MIN_QUOTE_CHARS, Rag::MAX_PAGES, Rag::MAX_PAGE_CHARS, Rag::MAX_UPLOAD_BYTES]
    assert_equal({"default_model" => "deepseek-flash", "temperature" => 0, "read_timeout" => 120, "disable_reasoning" => true},
                 Rag::LLM_SETTINGS)
  end

  def test_tenant_and_chunking_constants
    assert_equal ["nus", "acme"], Rag::TENANTS
    assert_equal "nus", Rag::DEFAULT_TENANT
    assert_equal "semantic", Rag::CHUNKING
    assert_equal 25, Rag::SEMANTIC_PERCENTILE
  end

  def test_string_list_type
    assert_equal ["a", "b"], load_yaml("l: [a, b]", {"l" => :string_list})["l"]
    ["l: []", "l: [a, 1]", "l: x"].each do |text|
      e = assert_raises(Rag::Error) { load_yaml(text, {"l" => :string_list}) }
      assert_includes e.message, "l must be a list of strings"
    end
  end

  def test_load_tenants_rejects_default_outside_list
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tenants.yaml")
      File.write(path, "tenants: [a]\ndefault: b\n")
      e = assert_raises(Rag::Error) { Rag.load_tenants(path) }
      assert_includes e.message, "default must be one of tenants"
    end
  end

  def test_doc_current_on_is_inclusive
    d1 = Date.new(2026, 1, 1)
    d2 = Date.new(2026, 12, 31)
    doc = Rag::Doc.new(status: "done", valid_from: d1, valid_to: d2)
    assert doc.current?(d1)
    assert doc.current?(d2)
    refute doc.current?(d1 - 1)
    refute doc.current?(d2 + 1)
    refute Rag::Doc.new(status: "expired", valid_from: d1, valid_to: d2).current?(d1)
  end

  def test_hit_score_is_one_minus_distance
    assert_equal 0.75, Rag::Hit.new(distance: 0.25).score
  end

  def test_answer_status
    assert_equal "answered", Rag::Answer.new("t", true, []).status
    assert_equal "not_enough_information", Rag::Answer.new("t", false, []).status
  end

  def load_yaml(text, schema)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.yaml")
      File.write(path, text)
      Rag.load_settings(path, schema)
    end
  end

  def test_loader_accepts_valid_and_rejects_bad_files
    schema = {"a" => :integer, "t" => :number, "m" => :string, "b" => :boolean}
    assert_equal 1, load_yaml("a: 1\nt: 0\nm: x\nb: false\n", schema)["a"]
    {"a: 1\nt: 0\nm: x\n" => "missing key b", "a: 1.5\nt: 0\nm: x\nb: true\n" => "a must be an integer",
     "a: 1\nt: x\nm: x\nb: true\n" => "t must be a number", "a: 1\nt: 0\nm: 5\nb: true\n" => "m must be a string",
     "a: 1\nt: 0\nm: x\nb: yes_\n" => "b must be true or false", "" => "must be a mapping",
     "- a\n- b\n" => "must be a mapping"}.each do |text, msg|
      e = assert_raises(Rag::Error) { load_yaml(text, schema) }
      assert_includes e.message, "config/x.yaml: "
      assert_includes e.message, msg
    end
  end

  def test_answer_prompt_builds_without_other_files_loaded_first
    hit = Rag::Hit.new(filename: "a.pdf", page: 1, text: "x [S1] y", distance: 0.1)
    assert_includes Rag::Prompts.answer("q?", [hit]), "[S1] file=a.pdf page=1\nx  y\n[/S1]"
  end
end
