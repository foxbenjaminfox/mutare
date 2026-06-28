defmodule CalcTest do
  use ExUnit.Case

  # Two orders: one comfortably over the free-shipping threshold, one well
  # under it. This is the *ordinary* gap — both sides are checked, but neither
  # test sits on the boundary (a subtotal of exactly 50, or 49), so widening or
  # nudging the `>= 50` comparison stays invisible.

  test "a large order ships free" do
    assert Calc.total(80) == 80
  end

  test "a small order pays the flat fee" do
    assert Calc.total(20) == 25
  end
end
