defmodule Mutare.Mutators.PeriodBoundary do
  @moduledoc """
  Exchanges the beginning and end of a calendar period:

    * `Date.beginning_of_month` ↔ `Date.end_of_month`
    * `Date.beginning_of_week` ↔ `Date.end_of_week`
    * `NaiveDateTime.beginning_of_day` ↔ `NaiveDateTime.end_of_day`

  Only the function name changes. Optional arguments are retained, so
  `Date.beginning_of_week(date, :sunday)` becomes
  `Date.end_of_week(date, :sunday)`. The weekday may be changed separately by
  `Mutare.Mutators.ModeSwap`.

  `Mutare.Mutators.CallRemoval` may produce another mutant at the same call by
  removing the boundary operation entirely. This family retains the call and changes
  its direction.

  Direct, aliased, and imported calls are supported. An alias that resolves to
  another module does not match. This family is enabled by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # {alias_path, function} => opposite-boundary function. The swap stays within the module,
  # so only the new name is stored; `Helpers.swap_call/2` keeps the written module and is
  # arity-blind (the optional `starting_on` on the week pair rides along unchanged).
  @swaps %{
    {[:Date], :beginning_of_month} => :end_of_month,
    {[:Date], :end_of_month} => :beginning_of_month,
    {[:Date], :beginning_of_week} => :end_of_week,
    {[:Date], :end_of_week} => :beginning_of_week,
    {[:NaiveDateTime], :beginning_of_day} => :end_of_day,
    {[:NaiveDateTime], :end_of_day} => :beginning_of_day
  }

  @impl Mutare.Mutator
  def name, do: :period_boundary

  @impl Mutare.Mutator
  def mutate(node), do: Helpers.swap_call(node, @swaps)
end
