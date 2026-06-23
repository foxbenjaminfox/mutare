defmodule Mutare.Mutators.GuardDrop do
  @moduledoc """
  Remove a clause's `when` guard entirely, broadening the clause to match
  unconditionally:

      def f(x) when is_binary(x), do: …   →   def f(x), do: …
      case v do x when is_atom(x) -> … end →   case v do x -> … end

  The highest-signal question a guard can be asked: *is this guard load-bearing at
  all?* If the suite never exercises an input the guard is meant to reject, the
  whole guard can vanish and every test still passes — a precisely located gap.

  Removes the guard at every clause head — `def`/`defp`, `case`, `receive`, and `fn`.
  On by default, named `:guard_drop` in reports, selectable via `:mutators`, filterable
  by `# mutare:ignore[guard_drop]`. The one construct it skips is a multi-pattern `fn`
  clause (`fn x, y when … -> …`), where the report diff can't cleanly render the
  guardless head.

  ## What it deliberately leaves alone — the "incidentally covered" rule

  A guard removal is only offered when **no other enabled mutator already mutates
  anything inside the guard**. If some family is already probing the guard, a full
  removal would pile a redundant mutant on top — so only an **inert** guard, one no
  other family touches, earns the removal, because there the removal is the *only*
  signal. Concretely:

    * `when x > 0`, `when a == b`, `when a and b` — a boolean operator: Relational/
      Logical/Conditional/Literal already mutate it (and Conditional's `→ true` is
      itself equivalent to removing the guard). **Skipped.**
    * `when Integer.is_even(x)` — the `Integer` family swaps it to `is_odd`.
      **Skipped.**
    * `when abs(x) > 0` — Relational on `>`, CallRemoval on `abs`. **Skipped.**
    * `when is_binary(x)`, `when is_atom(x)`, `when x`, a custom `defguard` — no
      family touches it. **Removed** — this is the motivating case, where a single
      type-guard would otherwise survive completely unmutated.

  The rule is *relative to the enabled set*: disable `Integer`, and
  `when Integer.is_even(x)` becomes genuinely uncovered, so guard removal is then
  offered there. No hard-coded list of "coverable" guards — the dedup is derived
  from what the mutators actually produce.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :guard_drop

  # Structural, not node-level: a clause's `when` is invisible to a node mutator,
  # so this never fires here. `Mutare.Transform` is the real driver (see the
  # moduledoc); it discovers a removable guard positionally and gates it on this
  # family being enabled.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip
end
