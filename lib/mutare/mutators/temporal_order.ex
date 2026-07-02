defmodule Mutare.Mutators.TemporalOrder do
  @moduledoc """
  Exchanges temporal ordering predicates:

    * `Date.before?` ↔ `Date.after?`
    * `Time.before?` ↔ `Time.after?`
    * `DateTime.before?` ↔ `DateTime.after?`
    * `NaiveDateTime.before?` ↔ `NaiveDateTime.after?`

  These calls express the same polarity as `<` and `>` for calendar/time structs. Swapping the predicate asks whether a suite actually covers the ordering direction rather than only equality or same-side examples.

  Direct, aliased, and imported calls are supported. An alias that resolves to another module does not match. This family is enabled by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  @modules [[:Date], [:Time], [:DateTime], [:NaiveDateTime]]

  @swaps for module <- @modules,
             {from, to} <- [before?: :after?, after?: :before?],
             into: %{},
             do: {{module, from}, to}

  @impl Mutare.Mutator
  def name, do: :temporal_order

  @impl Mutare.Mutator
  def mutate(node), do: Helpers.swap_call(node, @swaps)
end
