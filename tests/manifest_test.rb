require "test_helper"
require "tmpdir"

class ManifestTest < Minitest::Test
  def load_yaml(body)
    Dir.mktmpdir { |d| File.write(f = File.join(d, "m.yml"), body); Rag::Manifest.load(f) }
  end

  ENTRY = 'tenant: nus, title: T, version: 1, valid_from: "2026-01-01", valid_to: "2026-12-31"'.freeze

  def test_loads_keyed_by_basename
    m = load_yaml("- {out: data/raw/a.pdf, #{ENTRY}}\n- {out: x/b.docx, #{ENTRY}}\n")
    assert_equal %w[a.pdf b.docx], m.keys
    assert_equal "nus", m["a.pdf"].tenant_id
  end

  def test_entry_missing_version_raises_naming_it
    e = assert_raises(Rag::Meta::Invalid) { load_yaml("- {out: a.pdf, tenant: nus, title: T, valid_from: \"2026-01-01\", valid_to: \"2026-12-31\"}\n") }
    assert_includes e.message, "a.pdf"
    assert_equal :version, e.field
  end

  def test_real_manifest_loads
    assert_equal 4, Rag::Manifest.load.size
  end
end
