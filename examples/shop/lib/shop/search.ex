defmodule Shop.Search do
  @moduledoc """
  Product search, written with the `Shop.Query` DSL.

  The `matching/2` conditions read like query expressions. Because `.mutare.exs`
  skips that macro argument, the comparisons inside them (`<=`, `==`) produce no
  mutants. Remove the `macro_routes:` line from `.mutare.exs` and re-run to watch a
  cluster of relational/condition mutants appear in this file — the cost of
  letting Mutare mutate a query DSL it can't tell from ordinary code.
  """

  import Shop.Query

  @doc "Products priced at or below `budget`."
  def within_budget(products, budget) do
    matching(products, row.price <= budget)
  end

  @doc "Products in `category`."
  def in_category(products, category) do
    matching(products, row.category == category)
  end
end
