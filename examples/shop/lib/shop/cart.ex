defmodule Shop.Cart do
  @moduledoc """
  The cart itself: lines, membership, totals-feeding helpers.

  The collection-and-structure corner. Lists, maps, tuples, the `Enum` call
  rewrites, the `:ok`/`:error` convention tuples, and the pattern families
  (a swapped `{sku, qty}`, a repeated binding) all live here.
  """

  defstruct lines: [], coupon: nil

  @max_lines 50

  @doc "A fresh, empty cart."
  def new, do: %__MODULE__{}

  @doc "Add a line for `sku`, refusing to grow past the cart limit."
  def add(%__MODULE__{lines: lines} = cart, sku, quantity) when quantity > 0 do
    if length(lines) >= @max_lines do
      {:error, :cart_full}
    else
      line = %{sku: sku, quantity: quantity}
      {:ok, %{cart | lines: lines ++ [line]}}
    end
  end

  @doc "How many lines the cart holds."
  def line_count(%__MODULE__{lines: lines}), do: length(lines)

  @doc "Merge two lines for the *same* SKU into a single `{sku, quantity}`."
  def merge_lines({sku, first_qty}, {sku, second_qty}) do
    {sku, first_qty + second_qty}
  end

  @doc "Only the lines whose SKU currently has stock."
  def in_stock_lines(%__MODULE__{lines: lines}, stock) do
    Enum.filter(lines, fn line -> Map.get(stock, line.sku, 0) > 0 end)
  end

  @doc "The distinct SKUs in the cart, sorted."
  def skus(%__MODULE__{lines: lines}) do
    lines |> Enum.map(& &1.sku) |> Enum.uniq() |> Enum.sort()
  end

  @doc "Worth keeping on the list — in stock and not being cleared out?"
  def keep?(in_stock?, clearance?) do
    in_stock? and not clearance?
  end

  @doc "A label describing the cart's coupon, if it has one."
  def coupon_label(%__MODULE__{coupon: coupon}) do
    if coupon do
      "coupon " <> coupon
    else
      "no coupon"
    end
  end
end
