defmodule Shop.Query do
  @moduledoc """
  A one-macro, in-memory query DSL standing in for `Ecto.Query`.

  `matching/2` builds an `Enum.filter` at compile time, so its second argument
  is a query *expression* evaluated against each `row` — not ordinary runtime
  code. Used inside a function (as `Shop.Search` does), Mutare would otherwise
  splice mutation selectors into that expression; `.mutare.exs` lists the macro
  under `macros:` to leave the argument raw — the dependency-free twin of
  `{Ecto.Query, :from, :skip}`.
  """

  defmacro matching(source, condition) do
    quote do
      Enum.filter(unquote(source), fn var!(row) -> unquote(condition) end)
    end
  end
end
