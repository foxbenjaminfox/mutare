defmodule Shop.Catalog do
  @moduledoc """
  Product presentation: names, SKUs, categories, labels.

  The text-and-literal corner of the shop. Every literal lives in a function
  body (a value in a `@attribute` is compile-time and never mutated), so this
  module is where the string / sigil / regex / calendar / bitstring families
  land — alongside the `String` call rewrites.
  """

  @doc "Normalise a product name for display: surrounding space trimmed, upper-cased."
  def display_name(name) do
    name |> String.trim() |> String.upcase()
  end

  @doc "Does the SKU match the house format — three capitals, a dash, four digits?"
  def valid_sku?(sku) do
    String.match?(sku, ~r/^[A-Z]{3}-\d{4}$/)
  end

  @doc "Length of a product code, in characters."
  def code_length(code) do
    String.length(code)
  end

  @doc "Does `code` look like a clearance code (a `CLR` prefix)?"
  def clearance_code?(code) do
    String.starts_with?(code, "CLR")
  end

  @doc "The set of categories the storefront knows about."
  def categories do
    ~w(electronics books toys grocery)a
  end

  @doc "The storefront tagline."
  def tagline do
    ~s(Everything you need, delivered)
  end

  @doc "Bytes written to the (ancient) receipt printer to start a cut."
  def printer_cut do
    ~c"cut"
  end

  @doc "Pack an RGB swatch into three raw bytes."
  def swatch(red, green, blue) do
    <<red, green, blue>>
  end

  @doc "Encode a single Unicode code point for the label renderer."
  def glyph(codepoint) do
    <<codepoint::utf8>>
  end

  @doc "The first day of the month a dated promotion belongs to."
  def promo_month_start(date) do
    Date.beginning_of_month(date)
  end

  @doc "The default promotion's start date."
  def default_promo_date do
    ~D[2024-03-01]
  end

  @doc "The `n` priciest items first — the 'top deals' rail."
  def top_deals(prices, n) do
    prices |> Enum.sort(:desc) |> Enum.take(n)
  end

  @doc "Join category labels into one breadcrumb string."
  def breadcrumb(labels) do
    Enum.join(labels, " / ")
  end
end
