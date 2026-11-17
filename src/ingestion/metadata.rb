require "date"

module Rag
  Meta = Struct.new(:tenant_id, :title, :version, :valid_from, :valid_to, keyword_init: true)

  class Meta
    class Invalid < Rag::Error
      attr_reader :field

      def initialize(field, message)
        @field = field
        super(message)
      end
    end

    def self.parse(h)
      from = date(h[:valid_from], :valid_from)
      to = date(h[:valid_to], :valid_to)
      raise Invalid.new(:valid_to, "Ngày hết hiệu lực phải sau hoặc bằng ngày bắt đầu.") if from > to
      new(tenant_id: tenant(h[:tenant_id]), title: title(h[:title]), version: version(h[:version]), valid_from: from, valid_to: to)
    end

    def self.tenant(v)
      raise Invalid.new(:tenant_id, "Tenant không hợp lệ.") unless v.is_a?(String) && Rag::TENANTS.include?(v)
      v
    end

    def self.title(v)
      t = v.is_a?(String) ? Rag::Text.squash(v) : ""
      raise Invalid.new(:title, "Tiêu đề phải có từ 1 đến 200 ký tự.") unless (1..200).cover?(t.size)
      t
    end

    def self.version(v)
      n = v.is_a?(Integer) ? v : (v.is_a?(String) && v.match?(/\A\d+\z/) ? v.to_i : 0)
      raise Invalid.new(:version, "Phiên bản phải là số nguyên dương.") unless (1..2_147_483_647).cover?(n)
      n
    end

    def self.date(v, field)
      d = v if v.is_a?(Date)
      unless d
        raise ArgumentError unless v.is_a?(String) && v.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        d = Date.iso8601(v)
      end
      raise ArgumentError unless (1..9999).cover?(d.year) # Postgres date range
      d
    rescue ArgumentError # Date::Error is a subclass
      raise Invalid.new(field, "Ngày phải có dạng YYYY-MM-DD.")
    end
  end
end
