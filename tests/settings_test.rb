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
