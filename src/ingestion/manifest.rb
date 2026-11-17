require "yaml"

module Rag
  # data/samples/manifest.yml -> { nfc basename of "out" => Meta }
  module Manifest
    DEFAULT_PATH = File.expand_path("../../data/samples/manifest.yml", __dir__)
    KEYS = %i[tenant title version valid_from valid_to].freeze

    def self.load(path = DEFAULT_PATH)
      YAML.safe_load_file(path, symbolize_names: true, permitted_classes: [Date]).to_h do |e|
        name = Text.nfc(File.basename(e[:out].to_s))
        missing = KEYS.find { |k| e[k].nil? }
        raise Meta::Invalid.new(missing, "manifest: #{name}: thiếu #{missing}") if missing
        [name, Meta.parse(e.merge(tenant_id: e[:tenant]))]
      end
    end
  end
end
