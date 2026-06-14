defmodule Toy.CartTest do
  use ExUnit.Case

  alias Toy.Cart

  # subtotal: 10*2 + 5*1 = 25  (below the 50 free-shipping threshold)
  @items [%{price: 10, qty: 2}, %{price: 5, qty: 1}]

  test "subtotal sums price times quantity" do
    assert Cart.subtotal(@items) == 25
  end

  # NOTE: the gaps are deliberate.
  #
  #   * apply_discount/2 is only ever exercised here with percent: 0, which
  #     zeroes the discount term — so mutations of `-` and `/` in its body can't
  #     be told apart from the original (weak test data).
  #   * free_shipping?/1 is never tested at or above the threshold, so the
  #     boundary mutation `>= -> >` slips through (missing boundary test).
  test "total adds shipping below the free-shipping threshold" do
    assert Cart.total(@items, 0, 7) == 32
  end
end
