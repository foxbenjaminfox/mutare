defmodule Mutare.Mutators.OperandSwap do
  @moduledoc """
  Operand-order swaps for **non-commutative** binary operators: `a - b` → `b - a`,
  `a / b` → `b / a`, `a ** b` → `b ** a`, `a <> b` → `b <> a`, `a ++ b` → `b ++ a`,
  `a -- b` → `b -- a`, the function-call forms `div(a, b)` → `div(b, a)`,
  `rem(a, b)` → `rem(b, a)`, the **non-commutative date/time calls**
  `DateTime.before?(a, b)` → `DateTime.before?(b, a)` (likewise `after?`),
  `DateTime.compare(a, b)` → `DateTime.compare(b, a)`, and
  `DateTime.diff(a, b, unit)` → `DateTime.diff(b, a, unit)` (with the `Date` /
  `Time` / `NaiveDateTime` twins), the **version comparison**
  `Version.compare(a, b)` → `Version.compare(b, a)`, and the **non-commutative
  `MapSet` calls** `MapSet.difference(a, b)` → `MapSet.difference(b, a)` and
  `MapSet.subset?(a, b)` → `MapSet.subset?(b, a)`.

  The complement of `Mutare.Mutators.Arithmetic`/`List`, which swap the *operator*
  and keep the operands; this keeps the operator and swaps the operands. It catches
  the symmetric class of bugs those miss — code that gets the operator right but the
  argument order wrong (`elapsed = finish - start` written `start - finish`,
  `path <> sep` written `sep <> path`, `DateTime.before?(deadline, now)` written
  `DateTime.before?(now, deadline)`).

  ## Which operators (and why not the others)

  Only operators where order is *observable and the swap stays legal* are included:

    * `-`, `/`, `**` — arithmetic / power; non-commutative. (`+`, `*` are
      commutative — a swap is a guaranteed equivalent no-op, excluded.)
    * `<>` — binary concatenation; order matters.
    * `++`, `--` — list concat / difference; order matters. (Distinct from
      `Mutare.Mutators.List`, which swaps `++`↔`--`; here the operator is kept.)
    * `div`, `rem` — integer division / remainder.

  Deliberately **excluded**:

    * **Comparison operators** (`>`, `>=`, `<`, `<=`) — swapping operands is
      semantically identical to flipping direction (`a > b` ≡ `b < a`), which
      `Mutare.Mutators.Relational` already produces. (This is about the *operators*:
      the date/time comparison *call* `DateTime.before?` is included — no family flips
      its direction, so the swap is not a duplicate. See below.)
    * **Commutative operators** (`+`, `*`, `==`, `!=`, `===`, `!==`, `and`, `or`,
      `&&`, `||`) — the result is order-independent, so the mutant is equivalent.
      (Boolean ops are owned by `Mutare.Mutators.Logical`.)
    * **`in`** — `x in [1, 2]` swapped to `[1, 2] in x` is generally not
      compile-safe (the RHS must be enumerable), so it is left out.
    * **`=`, `|>`** — swapping operands changes binding / data-flow semantics.

  ## Remote non-commutative calls (`DateTime`/`Date`/`Time`/`NaiveDateTime`, `Version`, `MapSet`)

  The operand-swap idea applied to named *calls*: keep the function, transpose the first
  two arguments. Three date/time families qualify, on every calendar type (`DateTime`,
  `Date`, `Time`, `NaiveDateTime`):

    * `before?(a, b)` → `before?(b, a)` and `after?(a, b)` → `after?(b, a)` — the
      chronological-comparison direction flip (`before?(b, a)` ≡ `after?(a, b)`). No
      operator/relational family covers a `before?`/`after?` call, so this is not a
      duplicate of the excluded comparison operators above.
    * `compare(a, b)` → `compare(b, a)` — the three-way comparison; the swap inverts
      `:lt` ↔ `:gt` (and leaves `:eq`), the same direction flip as `before?`.
    * `diff(a, b)` / `diff(a, b, unit)` → `diff(b, a)` / `diff(b, a, unit)` — negates
      the difference. The **trailing `unit`** is kept untouched: it is a mode atom that
      `Mutare.Mutators.ModeSwap` already mutates, so the two families cover the call's
      two independent axes (argument order, time unit) as separate mutants. `Date.diff/2`
      carries no unit (it is always in days), so only the two-argument transpose applies
      there — `Date.diff(a, b)` → `Date.diff(b, a)`.

  Two more non-commutative calls join them, the same way:

    * `Version.compare(a, b)` → `Version.compare(b, a)` — the three-way version
      comparison; like `DateTime.compare` the swap inverts `:lt` ↔ `:gt` (and leaves
      `:eq`). No family flips its direction, so it is not a duplicate.
    * `MapSet.difference(a, b)` → `MapSet.difference(b, a)` — set difference is
      asymmetric (`a \\ b ≠ b \\ a`), and `MapSet.subset?(a, b)` →
      `MapSet.subset?(b, a)` — "is `a` a subset of `b`" is not "is `b` a subset of
      `a`". The complementary `MapSet.union` ↔ `MapSet.intersection` *name* swap is
      `Mutare.Mutators.MapSet`'s, not here (those are commutative — nothing to transpose).

  Matches aliased and imported calls too, while a shadowing `alias MyApp.DateTime`
  resolves elsewhere and is left alone.

  ## Skipped (equivalent or no operand to swap)

  When both operands are structurally identical — `x - x`, `5 / 5`, `acc ++ acc`,
  `DateTime.diff(t, t)` — the swap is a guaranteed no-op, so it is not emitted. A
  **piped** stage of any of these calls (`x |> div(b)`, `a |> DateTime.before?(b)`)
  draws its first operand from the pipe, so there is nothing local to transpose — also
  skipped. Unary minus (`-x`) is out of scope (nothing to swap; `Mutare.Mutators.Arithmetic`
  owns its removal).

  `-`, `/`, `div`, `rem` are guard-legal, so an instance inside a `when` guard is
  mutated too.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Calls

  # The non-commutative binary *operators* whose operands we transpose. Always written
  # infix (arity 2, never piped), so a plain `mutate/1` is enough. The call-form
  # `div`/`rem` are handled in `mutate/2` (they need the effective-arity safeguard).
  @operators [:-, :/, :**, :<>, :++, :--]

  # Bare `Kernel` call-form operators, swappable only at effective arity 2.
  @call_operators [:div, :rem]

  # Non-commutative *remote* stdlib calls whose first two arguments we transpose (the
  # operand-swap idea applied to a named call, as `div`/`rem` are). Keyed by the
  # resolved module (`Mutare.Transform.Calls`): the chronological comparisons `before?`
  # / `after?` / `compare` and the difference `diff` on every calendar type (`diff`'s
  # trailing time-unit atom is left in place — `Mutare.Mutators.ModeSwap` mutates that
  # axis), the three-way `Version.compare`, and the asymmetric `MapSet` operations
  # `difference` and `subset?` (`union`/`intersection` are commutative — that name swap
  # is `Mutare.Mutators.MapSet`'s).
  @remote_swaps MapSet.new([
                  {[:DateTime], :before?},
                  {[:Date], :before?},
                  {[:Time], :before?},
                  {[:NaiveDateTime], :before?},
                  {[:DateTime], :after?},
                  {[:Date], :after?},
                  {[:Time], :after?},
                  {[:NaiveDateTime], :after?},
                  {[:DateTime], :compare},
                  {[:Date], :compare},
                  {[:Time], :compare},
                  {[:NaiveDateTime], :compare},
                  {[:DateTime], :diff},
                  {[:Date], :diff},
                  {[:Time], :diff},
                  {[:NaiveDateTime], :diff},
                  {[:Version], :compare},
                  {[:MapSet], :difference},
                  {[:MapSet], :subset?}
                ])

  @impl Mutare.Mutator
  def name, do: :operand_swap

  @impl Mutare.Mutator
  def mutate({op, meta, [left, right]}) when op in @operators do
    if same?(left, right), do: :skip, else: [{op, meta, [right, left]}]
  end

  def mutate(_node), do: :skip

  # `div`/`rem`: bare `Kernel` calls. Transpose only a direct, non-piped two-argument
  # call — that is exactly effective arity 2 (the bare-`Kernel` safeguard from `Numeric`,
  # confirming the builtin over a same-named user `div/3`), and the only form that holds
  # both operands. A piped `x |> div(b)` supplies its first operand from the pipe, so
  # there is nothing local to transpose; effective arity 2 there has only one visible arg,
  # which fails the `[left, right]` match and is skipped.
  @impl Mutare.Mutator
  def mutate({op, meta, [left, right] = args}, %{pipe_mode: :unpiped})
      when op in @call_operators do
    if Mutare.Mutator.effective_arity(args, :unpiped) == 2 and not same?(left, right),
      do: [{op, meta, [right, left]}],
      else: :skip
  end

  # Non-commutative *remote* stdlib calls (`DateTime.before?`/`diff` and twins):
  # transpose the first two arguments, keeping the rest (`diff`'s trailing unit rides
  # along — ModeSwap owns it). Resolved through `Mutare.Transform.Calls`, so direct,
  # aliased, and imported forms all match and a shadowing alias resolves elsewhere.
  # Non-piped only: a piped stage draws its first operand from the pipe, so it has only
  # one local operand to swap — the `[a, b | rest]` destructure fails and it is skipped.
  def mutate(node, %{pipe_mode: :unpiped}) do
    with {module, fun, [a, b | rest], rebuild} <- Calls.resolved_call(node),
         true <- MapSet.member?(@remote_swaps, {module, fun}),
         false <- same?(a, b) do
      [rebuild.(fun, [b, a | rest])]
    else
      _ -> :skip
    end
  end

  def mutate(_node, _context), do: :skip

  # Structural equality ignoring metadata — a transpose of identical operands is an
  # equivalent no-op (`x - x`, `5 / 5`, `-2 - -2`), so we suppress it rather than count it.
  defp same?(left, right) do
    strip(left) == strip(right)
  end

  # Strip metadata **recursively** — `Macro.update_meta/2` touches only the top node, which
  # leaves a compound operand's inner meta intact (`-2` is `{:-, _, [{:__block__, meta, [2]}]}`,
  # so two `-2`s differ only in that inner `meta`) and wrongly reports them as distinct.
  defp strip(node) do
    Macro.prewalk(node, fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end
end
