defmodule Mutare.Mutators.OperandSwap do
  @moduledoc """
  Operand-order swaps for **non-commutative** binary operators: `a - b` → `b - a`,
  `a / b` → `b / a`, `a ** b` → `b ** a`, `a <> b` → `b <> a`, `a ++ b` → `b ++ a`,
  `a -- b` → `b -- a`, and the function-call forms `div(a, b)` → `div(b, a)`,
  `rem(a, b)` → `rem(b, a)`.

  The complement of `Mutare.Mutators.Arithmetic`/`List`, which swap the *operator*
  and keep the operands; this keeps the operator and swaps the operands. It catches
  the symmetric class of bugs those miss — code that gets the operator right but the
  argument order wrong (`elapsed = finish - start` written `start - finish`,
  `path <> sep` written `sep <> path`).

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
      operand swap here would only manufacture a duplicate mutant.
    * **Commutative operators** (`+`, `*`, `==`, `!=`, `===`, `!==`, `and`, `or`,
      `&&`, `||`) — the result is order-independent, so the mutant is equivalent and
      would only inflate the denominator. (Boolean ops can differ in *side-effect*
      order, but the value is commutative and `Mutare.Mutators.Logical` owns them.)
    * **`in`** — `x in [1, 2]` swapped to `[1, 2] in x` is generally not
      compile-safe (the RHS must be enumerable), so it is left out.
    * **`=`, `|>`** — swapping operands changes binding / data-flow semantics and is
      not compile-safe.

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

  # The non-commutative binary *operators* whose operands we transpose. Always written
  # infix (arity 2, never piped), so a plain `mutate/1` is enough. The call-form
  # `div`/`rem` are handled in `mutate/2` (they need the effective-arity safeguard).
  @operators [:-, :/, :**, :<>, :++, :--]

  # Bare `Kernel` call-form operators, swappable only at effective arity 2.
  @call_operators [:div, :rem]

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

  def mutate(_node, _context), do: :skip

  # Structural equality ignoring metadata — a transpose of identical operands is an
  # equivalent no-op (`x - x`, `5 / 5`), so we suppress it rather than count it.
  defp same?(left, right) do
    strip(left) == strip(right)
  end

  defp strip(node), do: Macro.update_meta(node, fn _ -> [] end)
end
