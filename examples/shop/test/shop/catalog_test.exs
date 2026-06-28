defmodule Shop.CatalogTest do
  use ExUnit.Case

  alias Shop.Catalog

  test "display_name trims and upper-cases" do
    assert Catalog.display_name("  widget ") == "WIDGET"
  end

  test "valid_sku? accepts the house format and rejects others" do
    assert Catalog.valid_sku?("ABC-1234")
    refute Catalog.valid_sku?("ab-1")
  end

  test "code_length counts characters" do
    assert Catalog.code_length("ABCD") == 4
  end

  test "clearance_code? checks the CLR prefix" do
    assert Catalog.clearance_code?("CLR-9")
    refute Catalog.clearance_code?("ABC-1")
  end

  test "categories lists the known categories" do
    assert Catalog.categories() == [:electronics, :books, :toys, :grocery]
  end

  test "tagline and printer_cut are fixed literals" do
    assert Catalog.tagline() == "Everything you need, delivered"
    assert Catalog.printer_cut() == ~c"cut"
  end

  test "swatch packs three RGB bytes" do
    assert Catalog.swatch(1, 2, 3) == <<1, 2, 3>>
  end

  test "glyph encodes a code point as UTF-8" do
    assert Catalog.glyph(65) == "A"
  end

  test "promo_month_start moves to the first of the month" do
    assert Catalog.promo_month_start(~D[2024-03-15]) == ~D[2024-03-01]
  end

  test "default_promo_date is the start of March 2024" do
    assert Catalog.default_promo_date() == ~D[2024-03-01]
  end

  test "top_deals returns the n priciest, descending" do
    assert Catalog.top_deals([3, 1, 4, 1, 5], 2) == [5, 4]
  end

  test "breadcrumb joins labels with a separator" do
    assert Catalog.breadcrumb(["home", "toys", "blocks"]) == "home / toys / blocks"
  end
end
