require "test_helper"

class MetadataTest < Minitest::Test
  OK = { tenant_id: "nus", title: "Quy chế", version: 3, valid_from: "2026-01-01", valid_to: "2026-12-31" }.freeze

  def field_of(**over)
    e = assert_raises(Rag::Meta::Invalid) { Rag::Meta.parse(OK.merge(over)) }
    e.field
  end

  def test_valid_parse
    m = Rag::Meta.parse(OK.merge(version: "3", title: "  Quy   chế "))
    assert_equal 3, m.version
    assert_equal "Quy chế", m.title
    assert_equal Date.new(2026, 1, 1), m.valid_from
    assert_equal Date.new(2026, 12, 31), m.valid_to
    assert_equal Date.new(2026, 1, 1), Rag::Meta.parse(OK.merge(valid_from: Date.new(2026, 1, 1))).valid_from
  end

  def test_invalid_title
    assert_equal :title, field_of(title: " ")
    assert_equal :title, field_of(title: nil)
    assert_equal :title, field_of(title: "a" * 201)
    assert Rag::Meta.parse(OK.merge(title: "a" * 200))
  end

  def test_invalid_tenant
    ["NUS", " nus", "zzz", nil].each { |t| assert_equal :tenant_id, field_of(tenant_id: t) }
  end

  def test_invalid_version
    [0, -1, "1.5", "abc", nil, "0"].each { |v| assert_equal :version, field_of(version: v) }
  end

  def test_invalid_dates
    ["2026-13-01", "2026-1-1", "20260101", nil].each do |d|
      assert_equal :valid_from, field_of(valid_from: d)
      assert_equal :valid_to, field_of(valid_to: d)
    end
    assert_equal :valid_to, field_of(valid_from: "2026-12-31", valid_to: "2026-01-01")
    assert Rag::Meta.parse(OK.merge(valid_from: "2026-05-05", valid_to: "2026-05-05"))
  end
end
