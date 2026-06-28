defmodule Shop.CartTest do
  use ExUnit.Case

  alias Shop.Cart

  test "new builds an empty cart" do
    assert Cart.new() == %Cart{lines: [], coupon: nil}
  end

  test "add appends a line" do
    {:ok, cart} = Cart.add(Cart.new(), "ABC-0001", 2)
    assert cart.lines == [%{sku: "ABC-0001", quantity: 2}]
  end

  test "line_count counts the lines" do
    {:ok, cart} = Cart.add(Cart.new(), "ABC-0001", 2)
    assert Cart.line_count(cart) == 1
  end

  test "merge_lines sums quantities for the same SKU" do
    assert Cart.merge_lines({"ABC-0001", 1}, {"ABC-0001", 2}) == {"ABC-0001", 3}
  end

  test "in_stock_lines keeps only lines with stock" do
    {:ok, cart} = Cart.add(Cart.new(), "ABC-0001", 2)
    {:ok, cart} = Cart.add(cart, "ZZZ-9999", 1)
    stock = %{"ABC-0001" => 5, "ZZZ-9999" => 0}
    assert Cart.in_stock_lines(cart, stock) == [%{sku: "ABC-0001", quantity: 2}]
  end

  test "skus lists distinct SKUs, sorted" do
    {:ok, cart} = Cart.add(Cart.new(), "DEF-0002", 1)
    {:ok, cart} = Cart.add(cart, "ABC-0001", 1)
    {:ok, cart} = Cart.add(cart, "ABC-0001", 3)
    assert Cart.skus(cart) == ["ABC-0001", "DEF-0002"]
  end

  test "keep? wants in-stock, non-clearance lines" do
    assert Cart.keep?(true, false)
    refute Cart.keep?(true, true)
    refute Cart.keep?(false, false)
  end

  test "coupon_label describes the coupon" do
    assert Cart.coupon_label(%Cart{coupon: "SAVE10"}) == "coupon SAVE10"
    assert Cart.coupon_label(%Cart{coupon: nil}) == "no coupon"
  end
end
