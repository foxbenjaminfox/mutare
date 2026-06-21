defmodule Mutare.Mutators.GuardDrop do
  @moduledoc """
  Remove a clause's `when` guard entirely, broadening the clause to match
  unconditionally:

      def f(x) when is_binary(x), do: …   →   def f(x), do: …
      case v do x when is_atom(x) -> … end →   case v do x -> … end

  The highest-signal question a guard can be asked: *is this guard load-bearing at
  all?* If the suite never exercises an input the guard is meant to reject, the
  whole guard can vanish and every test still passes — a precisely located gap.

  ## Why this is structural, not a node-level `mutate/1`

  Like `Mutare.Mutators.ReturnValue` and the pattern families, this targets a
  *position* (a clause's `when`), not a node a `mutate/1` could match — so
  `mutate/1` is `:skip` and the real work is done by `Mutare.Transform`, which
  discovers a removable guard at every clause head it routes (`def`/`defp` heads
  via lifting, `case` clauses via the tuple-the-scrutinee rewrite, `receive`/`fn`
  clauses via the whole-construct selector). This module exists only to sit in the
  `Mutare.Mutators` registry — be on by default, be named `:guard_drop` in reports,
  be selected/validated via `:mutators`, and be filtered by
  `# mutare:ignore[guard_drop]` — exactly like every other family.

  Compile-safety is free: dropping a `when` always leaves a legal clause (the head
  pattern is untouched). The only construct it skips is a **multi-pattern `fn`
  clause** (`fn x, y when … -> …`), where the report diff can't cleanly render the
  guardless head — rare, and documented in NOTES.

  ## What it deliberately leaves alone — the "incidentally covered" rule

  A guard removal is only offered when **no other enabled mutator already mutates
  anything inside the guard**. The transform already tags every mutatable guard
  node (`Mutare.Transform.Tag.guard_targets/3`); if that yields *any* target, some
  family is already probing the guard, so a full removal would pile a redundant
  mutant on top. Only an **inert** guard — one no other family touches — earns the
  removal, because there the removal is the *only* signal. Concretely:

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
