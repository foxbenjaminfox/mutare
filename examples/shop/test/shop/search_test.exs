defmodule Shop.SearchTest do
  use ExUnit.Case

  alias Shop.Search

  @products [
    %{sku: "ABC-0001", price: 5, category: :books},
    %{sku: "DEF-0002", price: 20, category: :toys}
  ]

  test "within_budget keeps products at or below the budget" do
    assert Search.within_budget(@products, 10) == [
             %{sku: "ABC-0001", price: 5, category: :books}
           ]
  end

  test "in_category keeps products in the category" do
    assert Search.in_category(@products, :toys) == [
             %{sku: "DEF-0002", price: 20, category: :toys}
           ]
  end
end
