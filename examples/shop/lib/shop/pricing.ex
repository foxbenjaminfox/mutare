defmodule Shop.Pricing do
  @moduledoc """
  Money: line totals, discounts, tax, tiers.

  The arithmetic heart of the shop, so this is where the operator and number
  families concentrate — `+ - * /`, operand order, the rounding/`min`/`max`
  builtins, the `:math` calls, and float literals. The thresholds also drive
  the comparison/condition families.
  """

  @doc "Line total: unit price times quantity, less a per-line discount."
  def line_total(unit_price, quantity, discount) do
    unit_price * quantity - discount
  end

  @doc "The mid-point of a `{low, high}` price band."
  # mutare:ignore[pattern_swap] a midpoint is symmetric in its endpoints
  def mid_price({low, high}) do
    (low + high) / 2
  end

  @doc "Apply a percentage discount, clamped so it never goes negative."
  def discounted(amount, percent) do
    reduced = amount - amount * percent / 100
    max(reduced, 0.0)
  end

  @doc "Sales tax at the standard rate, rounded to the cent."
  def tax(amount) do
    Float.round(amount * 0.0825, 2)
  end

  @doc "Whole cents in an amount, rounded to the nearest cent."
  def to_cents(amount) do
    round(amount * 100)
  end

  @doc "Floor an amount down to whole cents (two decimal places)."
  def floor_cents(amount) do
    Float.floor(amount, 2)
  end

  @doc "A crude popularity score on a log scale."
  def popularity(review_count) do
    # mutare:ignore[math] only the relative ranking matters, not the log base
    :math.log(review_count + 1)
  end

  @doc "Is this the shop's native currency?"
  def native_currency?(currency) do
    # mutare:ignore[strict_equality:==] atoms compare the same under == and ===
    currency === :usd
  end

  @doc "Price tier for an amount."
  def tier(amount) do
    if amount >= 100.0 do
      :premium
    else
      :standard
    end
  end

  @doc "Fill in default pricing options and drop any debug switch."
  def normalize_opts(opts) do
    opts
    |> Keyword.put_new(:currency, :usd)
    |> Keyword.delete(:debug)
  end
end
