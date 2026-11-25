# Strict parsing of user-typed decimals (ORD-02, DEP-01): plain digits with an optional
# fraction. No sign, exponent, spaces, NaN or Infinity, and no silent rounding.
module DecimalInput
  PATTERN = /\A\d+(\.\d+)?\z/

  module_function

  # Returns nil when blank/nil. Raises ApiError(:validation_failed) otherwise on bad input.
  def parse(value, name, max_places:)
    return nil if value.nil?
    str = value.is_a?(Numeric) ? numeric_to_s(value) : value.to_s
    raise ApiError.new(:validation_failed, "#{name} is required") if str.empty?
    raise ApiError.new(:validation_failed, "#{name} must be a plain number") unless str.match?(PATTERN)
    dec = BigDecimal(str)
    raise ApiError.new(:validation_failed, "#{name} must be greater than zero") unless dec.positive?
    if dec.scale > max_places
      raise ApiError.new(:validation_failed, "#{name} can have at most #{max_places} decimal places")
    end
    dec
  end

  def numeric_to_s(n)
    return n.to_s if n.is_a?(Integer)
    return n.to_s("F") if n.is_a?(BigDecimal)
    s = n.to_s
    s.match?(/e/i) ? format("%.12f", n).sub(/0+\z/, "") : s
  end
end
