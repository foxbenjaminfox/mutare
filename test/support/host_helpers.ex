defmodule Mutare.Test.HostHelpers do
  @moduledoc """
  The AST readers the host-mutator fixtures in `host_mutator.ex` share: recognising and
  reversing the four ordering comparisons, and the keyword-list shape.

  Each fixture keeps its routes and `host/2` self-contained — they double as the documented
  examples of the extension surface — so only these leaf helpers are common. `import` it.
  """

  @comparisons [:>, :<, :>=, :<=]

  @doc "Guard: `op` is one of `>`, `<`, `>=`, `<=`."
  defguard is_comparison(op) when op in @comparisons

  @doc "Is `node` a binary comparison call?"
  def comparison?({op, _meta, [_left, _right]}) when is_comparison(op), do: true
  def comparison?(_node), do: false

  @doc "The comparison read right to left: `>` ↔ `<`, `>=` ↔ `<=`."
  def reverse(:>), do: :<
  def reverse(:<), do: :>
  def reverse(:>=), do: :<=
  def reverse(:<=), do: :>=

  @doc "A non-empty list of `{key, value}` pairs."
  def keyword_list?(list) when is_list(list) and list != [],
    do: Enum.all?(list, &match?({_k, _v}, &1))

  def keyword_list?(_node), do: false
end
