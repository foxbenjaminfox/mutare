defmodule Toy.Cart do
  @moduledoc "Tiny shopping-cart pricing — a demonstration target for Mutare."

  @free_shipping_threshold 50

  @doc "Sum of line items (price × quantity)."
  def subtotal(items) do
    Enum.reduce(items, 0, fn %{price: price, qty: qty}, acc ->
      acc + price * qty
    end)
  end

  @doc """
  Apply a whole-number percentage discount to an amount.

  The `when` guard is intentionally present: Mutare's in-place mutators must
  *skip* operators inside guards (a `case` is illegal there), so none of these
  comparisons become mutants in M1 — only the body arithmetic does.
  """
  def apply_discount(amount, percent) when percent >= 0 and percent <= 100 do
    amount - amount * percent / 100
  end

  @doc "Free shipping once the subtotal reaches the threshold."
  def free_shipping?(subtotal) do
    subtotal >= @free_shipping_threshold
  end

  @doc "Grand total: discounted subtotal, plus shipping unless it ships free."
  def total(items, percent, shipping) do
    sub = subtotal(items)
    discounted = apply_discount(sub, percent)

    if free_shipping?(sub) do
      discounted
    else
      discounted + shipping
    end
  end
end
