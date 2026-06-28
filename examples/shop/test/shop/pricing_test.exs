defmodule Shop.PricingTest do
  use ExUnit.Case

  alias Shop.Pricing

  test "line_total multiplies then subtracts the discount" do
    assert Pricing.line_total(10, 3, 5) == 25
  end

  test "mid_price averages a band" do
    assert Pricing.mid_price({10, 20}) == 15.0
  end

  test "discounted applies a percentage and floors at zero" do
    assert Pricing.discounted(100, 10) == 90.0
    assert Pricing.discounted(100, 200) == 0.0
  end

  test "tax rounds to the cent" do
    assert Pricing.tax(100.0) == 8.25
  end

  test "to_cents rounds to the nearest cent" do
    assert Pricing.to_cents(9.5) == 950
  end

  test "floor_cents floors to two decimals" do
    assert Pricing.floor_cents(9.999) == 9.99
  end

  test "popularity is a log-scale score" do
    assert Pricing.popularity(0) == 0.0
  end

  test "native_currency? recognises USD" do
    assert Pricing.native_currency?(:usd)
    refute Pricing.native_currency?(:eur)
  end

  test "tier splits on the premium threshold" do
    assert Pricing.tier(150.0) == :premium
    assert Pricing.tier(50.0) == :standard
  end

  test "normalize_opts fills the currency default and drops debug" do
    assert Pricing.normalize_opts(debug: true) == [currency: :usd]
  end
end
