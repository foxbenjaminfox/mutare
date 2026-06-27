defmodule Mutare.Mutators.PeriodBoundary do
  @moduledoc """
  Swap a calendar **period-boundary** call for its opposite end — does the code use the
  *start* or the *end* of the month / week / day?

    * `Date.beginning_of_month` ↔ `Date.end_of_month`
    * `Date.beginning_of_week` ↔ `Date.end_of_week`
    * `NaiveDateTime.beginning_of_day` ↔ `NaiveDateTime.end_of_day`

  The date/time sibling of `Mutare.Mutators.Collection`/`Mutare.Mutators.StringCall` (the
  `first`↔`last`, `starts_with?`↔`ends_with?` directional swaps): both ends return the
  **same type** (`Date`→`Date`, `NaiveDateTime`→`NaiveDateTime`) and a different boundary,
  so the swap is compile-safe and never equivalent. A survivor means no test pins down
  *which* end of the period the code computes — the classic off-by-a-boundary bug at a
  reporting-window or billing-cycle edge.

  **Arity-blind**, like its siblings: `beginning_of_week`/`end_of_week` carry an optional
  `starting_on` weekday (`/2`) that rides along unchanged on the swap
  (`Date.beginning_of_week(d, :sunday)` → `Date.end_of_week(d, :sunday)`) — mutating *that*
  weekday is `Mutare.Mutators.ModeSwap`'s job, an orthogonal axis. `DateTime` has no
  `beginning_of_day`/`end_of_day`, and `Time` no period boundaries, so neither appears here.

  Distinct from `Mutare.Mutators.CallRemoval`, which *removes* these same boundary
  normalizers (→ the original timestamp); here the call is kept and its direction flipped —
  a different mutant on the same call.

  On by default. Matches aliased and bare-imported calls too (`alias Date, as: D;
  D.beginning_of_month` → `D.end_of_month`), while a shadowing `alias MyApp.Date` is left
  alone.
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
