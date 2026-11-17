require "test_helper"
require "puma"
require "puma/configuration"

class PumaConfigTest < Minitest::Test
  def test_body_size_limit_is_set_above_the_upload_limit
    conf = Puma::Configuration.new({ config_files: [File.expand_path("../config/puma.rb", __dir__)] })
    conf.clamp
    limit = conf.options[:http_content_length_limit]
    assert_equal 32 * 1024 * 1024, limit
    assert_operator limit, :>, Rag::MAX_UPLOAD_BYTES
  end
end
