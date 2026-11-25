# Decimals leave the API as strings with a fixed number of places. Never floats.
module Fmt
  module_function

  def dec(value, places)
    return nil if value.nil?
    v = value.to_d.round(places).to_d # round(0) would return an Integer
    v = BigDecimal("0") if v.zero? # avoid "-0.00"
    str = v.to_s("F")
    int, frac = str.split(".")
    frac = (frac || "").ljust(places, "0")
    places.zero? ? int : "#{int}.#{frac}"
  end

  def money(v) = dec(v, 2)
  def price(v) = dec(v, 8)
  def qty(v) = dec(v, 8)
  def iso(t) = t&.utc&.iso8601
end
