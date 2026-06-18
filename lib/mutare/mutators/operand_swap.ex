defmodule Mutare.Mutators.OperandSwap do
  @moduledoc """
  Operand-order swaps for **non-commutative** binary operators: `a - b` → `b - a`,
  `a / b` → `b / a`, `a ** b` → `b ** a`, `a <> b` → `b <> a`, `a ++ b` → `b ++ a`,
  `a -- b` → `b -- a`, the bare-`Kernel` function-call forms `div(a, b)` → `div(b, a)`,
  `rem(a, b)` → `rem(b, a)`, and the **non-commutative date/time calls**
  `DateTime.before?(a, b)` → `DateTime.before?(b, a)` (likewise `after?`),
  `DateTime.compare(a, b)` → `DateTime.compare(b, a)`, and
  `DateTime.diff(a, b, unit)` → `DateTime.diff(b, a, unit)` (with the `Time` /
  `NaiveDateTime` twins).

  The complement of `Mutare.Mutators.Arithmetic`/`List`, which swap the *operator*
  and keep the operands; this keeps the operator and swaps the operands. It catches
  the symmetric class of bugs those miss — code that gets the operator right but the
  argument order wrong (`elapsed = finish - start` written `start - finish`,
  `path <> sep` written `sep <> path`, `DateTime.before?(deadline, now)` written
  `DateTime.before?(now, deadline)`).

  In-place and **compile-safe by construction**: the mutant reuses both original
  operand subtrees, just transposed, so whatever type-checked before still does.

  ## Which operators (and why not the others)

  Only operators where order is *observable and the swap stays legal* are included:

    * `-`, `/`, `**` — arithmetic / power; non-commutative. (`+`, `*` are
      commutative, so a swap is a guaranteed equivalent no-op — excluded.)
    * `<>` — binary concatenation; order matters.
    * `++`, `--` — list concat / difference; order matters. (Distinct from
      `Mutare.Mutators.List`, which swaps `++`↔`--`; here the operator is kept.)
    * `div`, `rem` — integer division / remainder. These are bare `Kernel` *calls*
      (not operators), so — like the bare-`Kernel` rule in `Mutare.Mutators.Numeric` —
      the swap is gated on **effective arity 2** (`mutate/2`, pipe-aware): that both
      confirms the builtin (a same-named user `div/3` is left alone) and guarantees
      the node holds *both* operands to transpose. A piped stage (`x |> div(b)`) draws
      its first operand from the pipe, so it has nothing local to swap — skipped.

  Deliberately **excluded**:

    * **Comparison operators** (`>`, `>=`, `<`, `<=`) — swapping operands is
      semantically identical to flipping direction (`a > b` ≡ `b < a`... and
      `b > a` ≡ `a < b`), which `Mutare.Mutators.Relational` already produces. An
      operand swap here would only manufacture a duplicate mutant. (This is about the
      *operators*: the date/time comparison *call* `DateTime.before?` is included — no
      family flips its direction, so the swap is not a duplicate. See below.)
    * **Commutative operators** (`+`, `*`, `==`, `!=`, `===`, `!==`, `and`, `or`,
      `&&`, `||`) — the result is order-independent, so the mutant is equivalent and
      would only inflate the denominator. (Boolean ops can differ in *side-effect*
      order, but the value is commutative and `Mutare.Mutators.Logical` owns them.)
    * **`in`** — `x in [1, 2]` swapped to `[1, 2] in x` is generally not
      compile-safe (the RHS must be enumerable), so it is left out.
    * **`=`, `|>`** — swapping operands changes binding / data-flow semantics and is
      not compile-safe.

  ## Remote non-commutative calls (`DateTime`/`Time`/`NaiveDateTime`)

  The operand-swap idea applied to named *calls*, exactly as `div`/`rem` are: keep the
  function, transpose the first two arguments. Three date/time families qualify, on every
  calendar type (`DateTime`, `Time`, `NaiveDateTime`):

    * `before?(a, b)` → `before?(b, a)` and `after?(a, b)` → `after?(b, a)` — the
      chronological-comparison direction flip (`before?(b, a)` ≡ `after?(a, b)`). No
      operator/relational family covers a `before?`/`after?` call, so this is the *only*
      mutator that probes them — not a duplicate of the excluded comparison operators above.
    * `compare(a, b)` → `compare(b, a)` — the three-way comparison; the swap inverts
      `:lt` ↔ `:gt` (and leaves `:eq`), the same direction flip as `before?`.
    * `diff(a, b)` / `diff(a, b, unit)` → `diff(b, a)` / `diff(b, a, unit)` — negates
      the difference. The **trailing `unit`** is kept untouched: it is a mode atom that
      `Mutare.Mutators.ModeSwap` already mutates (`{[:DateTime], :diff, 3}` et al.), so
      the two families cover the call's two independent axes (argument order, time unit)
      as separate mutants.

  Resolved through the shared `Mutare.Transform.Calls` reader, so direct, aliased
  (`alias DateTime, as: DT; DT.before?(a, b)`), and bare-imported forms all match, while
  a shadowing `alias MyApp.DateTime` resolves elsewhere and is left alone. Like the
  `div`/`rem` call forms these are **non-piped only**: a piped stage
  (`a |> DateTime.before?(b)`) draws its first operand from the pipe, so the node holds
  only one local operand and there is nothing to transpose. Structurally identical first
  two operands (`DateTime.diff(t, t)`) are skipped, as for the operators.

  ## Identical operands are skipped

  When both operands are structurally identical (ignoring metadata) — `x - x`,
  `5 / 5`, `acc ++ acc` — the swap is a guaranteed no-op, so it is not emitted.

  ## Placement and guard-safety

  Placement is positional (decided by `Mutare.Transform`), not here. `-`, `/`,
  `div`, `rem` are guard-legal, so an instance inside a `when` guard is delivered by
  lifting like Arithmetic's; `**`, `<>`, `++`, `--` are not guard-legal, so the
  compiler guarantees they never appear in a guard for this mutator to reach.

  Unary minus (`-x`, arity 1) is out of scope — there is nothing to swap, and
  `Mutare.Mutators.Arithmetic` owns its removal.
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
  # / `after?` / `compare` and the difference `diff` on every calendar type. `diff`'s
  # trailing time-unit atom is left in place — `Mutare.Mutators.ModeSwap` mutates that axis.
  @remote_swaps MapSet.new([
                  {[:DateTime], :before?},
                  {[:Time], :before?},
                  {[:NaiveDateTime], :before?},
                  {[:DateTime], :after?},
                  {[:Time], :after?},
                  {[:NaiveDateTime], :after?},
                  {[:DateTime], :compare},
                  {[:Time], :compare},
                  {[:NaiveDateTime], :compare},
                  {[:DateTime], :diff},
                  {[:Time], :diff},
                  {[:NaiveDateTime], :diff}
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
  def mutate({op, meta, [left, right] = args}, %{piped: false})
      when op in @call_operators do
    if Mutare.Mutator.effective_arity(args, false) == 2 and not same?(left, right),
      do: [{op, meta, [right, left]}],
      else: :skip
  end

  # Non-commutative *remote* stdlib calls (`DateTime.before?`/`diff` and twins):
  # transpose the first two arguments, keeping the rest (`diff`'s trailing unit rides
  # along — ModeSwap owns it). Resolved through `Mutare.Transform.Calls`, so direct,
  # aliased, and imported forms all match and a shadowing alias resolves elsewhere.
  # Non-piped only: a piped stage draws its first operand from the pipe, so it has only
  # one local operand to swap — the `[a, b | rest]` destructure fails and it is skipped.
  def mutate(node, %{piped: false}) do
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
  # equivalent no-op (`x - x`, `5 / 5`), so we suppress it rather than count it.
  defp same?(left, right) do
    strip(left) == strip(right)
  end

  defp strip(node), do: Macro.update_meta(node, fn _ -> [] end)
end
