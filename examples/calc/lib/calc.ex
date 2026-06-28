defmodule Calc do
  @moduledoc """
  The smallest possible Mutare target: a single function with one ordinary gap.

  `total/1` adds shipping to an order subtotal — free once the order reaches a
  threshold, a flat fee otherwise. The test suite checks one order on each side
  of the threshold, which feels thorough but never pins the threshold *itself*.
  Mutare turns that gap into a surviving mutant: the classic off-by-one boundary
  that survives because no test sits exactly on the line.
  """

  @free_shipping_over 50
  @flat_fee 5

  @doc "Order total: the subtotal, plus shipping (free once it's large enough)."
  def total(subtotal) do
    shipping = if subtotal >= @free_shipping_over, do: 0, else: @flat_fee
    subtotal + shipping
  end
end
