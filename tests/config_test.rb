require "test_helper"
require "pp"

class ConfigTest < Minitest::Test
  def test_missing_key_and_base_are_named_in_message
    e = assert_raises(Rag::ConfigError) { Rag::Config.from_env({}) }
    assert_includes e.message, "DEEPSEEK_API_KEY"
    assert_includes e.message, "DEEPSEEK_API_BASE"
  end

  def test_blank_value_counts_as_missing
    e = assert_raises(Rag::ConfigError) { Rag::Config.from_env("DEEPSEEK_API_KEY" => "  ", "DEEPSEEK_API_BASE" => "http://x") }
    assert_includes e.message, "DEEPSEEK_API_KEY"
    refute_includes e.message, "DEEPSEEK_API_BASE"
  end

  def test_defaults_and_values
    c = Rag::Config.from_env("DEEPSEEK_API_KEY" => "k", "DEEPSEEK_API_BASE" => "http://x", "DATABASE_URL" => "postgres://d")
    assert_equal "deepseek-flash", c.model
    assert_equal "postgres://d", c.database_url
    assert c.documents_dir.end_with?("data/raw")
  end

  def test_inspect_does_not_leak_key
    c = Rag::Config.from_env("DEEPSEEK_API_KEY" => "sekret-123", "DEEPSEEK_API_BASE" => "http://host.example")
    refute_includes c.inspect, "sekret-123"
    refute_includes c.to_s, "sekret-123"
    refute_includes c.inspect, "host.example"
    refute_includes c.pretty_inspect, "sekret-123"
    refute_includes c.pretty_inspect, "host.example"
  end

  def test_model_and_documents_dir_set_or_blank
    base = {"DEEPSEEK_API_KEY" => "k", "DEEPSEEK_API_BASE" => "http://x"}
    c = Rag::Config.from_env(base.merge("DEEPSEEK_MODEL" => "m1", "DOCUMENTS_DIR" => "/d"))
    assert_equal ["m1", "/d"], [c.model, c.documents_dir]
    c = Rag::Config.from_env(base.merge("DEEPSEEK_MODEL" => " ", "DOCUMENTS_DIR" => " "))
    assert_equal "deepseek-flash", c.model
    assert c.documents_dir.end_with?("data/raw")
  end

  def test_no_stray_required_constant
    refute Rag.const_defined?(:REQUIRED)
  end
end
