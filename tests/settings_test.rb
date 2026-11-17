require "test_helper"

class SettingsTest < Minitest::Test
  def test_yaml_settings_give_the_documented_constants
    assert_equal ["Xenova/multilingual-e5-small", 384, 6, 1000, 20, 10, 200, 20_000, 30 * 1024 * 1024],
                 [Rag::EMBED_MODEL, Rag::EMBED_DIM, Rag::TOP_K, Rag::MAX_CHUNK_CHARS, Rag::MIN_LETTERS,
                  Rag::MIN_QUOTE_CHARS, Rag::MAX_PAGES, Rag::MAX_PAGE_CHARS, Rag::MAX_UPLOAD_BYTES]
    assert_equal({"default_model" => "deepseek-flash", "temperature" => 0, "read_timeout" => 120, "disable_reasoning" => true},
                 Rag::LLM_SETTINGS)
  end
end
