defmodule Mutare.Mutators.OperandSwap do
  @moduledoc """
  Reverses the first two operands of non-commutative operators and calls.

  ## Operators

    * `-`, `/`, and `**`
    * `<>`
    * `++` and `--`
    * `div`, `rem` — integer division / remainder.

  The operator is retained; only the operands are exchanged.

  The following operators are excluded:

    * `>`, `>=`, `<`, and `<=`, because `Mutare.Mutators.Relational` already produces the equivalent direction change
    * commutative operators such as `+`, `*`, equality, and boolean operators
    * `in`, because the swapped right operand may not be enumerable
    * `=` and `|>`, whose operands have different roles

  ## Calls

  The first two arguments are exchanged in these calls:

    * `before?/2`, `after?/2`, `compare/2`, and `diff/2,3` on `DateTime`, `Date`, `Time`, and `NaiveDateTime`, where those functions exist
    * `Version.compare/2`
    * `MapSet.difference/2` and `MapSet.subset?/2`

  A trailing unit in `diff/3` is retained and may be mutated separately by `Mutare.Mutators.ModeSwap`.

  Aliased and imported calls are supported. An alias that resolves to another module does not match.

  ## Piped calls

  A pipe stage is the call it is sugar for, so its piped value is the first operand and the transpose moves it:

      foo |> Kernel.++(bar)  →  bar |> Kernel.++(foo)

  This is how a pipe expresses an operator, so the explicit `Kernel` call forms (`Kernel.++`, `Kernel.-`, `Kernel.<>`, `Kernel.div`, …) are transposed like the operators they name, written directly or piped.

  ## Skipped cases

  Identical operands are not swapped. Unary minus has no second operand and is handled by `Mutare.Mutators.Arithmetic`.

  Guard-safe operators and calls are also mutated in guards.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers
  alias Mutare.Transform.Calls

  # The non-commutative binary *operators* whose operands we transpose. Always written
  # infix. The call-form `div`/`rem` need the arity safeguard and are matched separately
  # (`call_mutations/1`).
  @operators [:-, :/, :**, :<>, :++, :--]

  # Bare `Kernel` call-form operators, swappable only at arity 2.
  @call_operators [:div, :rem]

  # Non-commutative *remote* stdlib calls whose first two arguments we transpose (the
  # operand-swap idea applied to a named call, as `div`/`rem` are). Keyed by the
  # resolved module (`Mutare.Transform.Calls`): the chronological comparisons `before?`
  # / `after?` / `compare` and the difference `diff` on every calendar type (`diff`'s
  # trailing time-unit atom is left in place — `Mutare.Mutators.ModeSwap` mutates that
  # axis), the three-way `Version.compare`, and the asymmetric `MapSet` operations
  # `difference` and `subset?` (`union`/`intersection` are commutative — that name swap
  # is `Mutare.Mutators.MapSet`'s).
  @stdlib_swaps MapSet.new([
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

  # Every transposable *remote* call: the table above, plus the operators and `div`/`rem`
  # written as the `Kernel` call they name — the form a pipe takes (`foo |> Kernel.++(bar)`).
  @remote_swaps MapSet.union(
                  @stdlib_swaps,
                  MapSet.new(for op <- @operators ++ @call_operators, do: {[:Kernel], op})
                )

  @impl Mutare.Mutator
  def name, do: :operand_swap

  defp operator_mutations({op, meta, [left, right]}) when op in @operators do
    if same?(left, right), do: :skip, else: [{op, meta, [right, left]}]
  end

  defp operator_mutations(_node), do: :skip

  @impl Mutare.Mutator
  def mutate(node),
    do: Helpers.combine_mutations(operator_mutations(node), call_mutations(node))

  # `div`/`rem`: bare `Kernel` calls, transposed only at arity 2 (the bare-`Kernel` safeguard
  # from `Numeric`, confirming the builtin over a same-named user `div/3`).
  defp call_mutations({op, meta, [left, right]}) when op in @call_operators do
    if same?(left, right), do: :skip, else: [{op, meta, [right, left]}]
  end

  # Non-commutative *remote* calls (`DateTime.before?`/`diff` and twins, `Kernel.++`):
  # transpose the first two arguments, keeping the rest (`diff`'s trailing unit rides
  # along — ModeSwap owns it). Resolved through `Mutare.Transform.Calls`, so direct,
  # aliased, and imported forms all match and a shadowing alias resolves elsewhere.
  defp call_mutations(node) do
    with {module, fun, [a, b | rest], rebuild} <- Calls.resolved_call(node),
         true <- MapSet.member?(@remote_swaps, {module, fun}),
         false <- same?(a, b) do
      [rebuild.(fun, [b, a | rest])]
    else
      _ -> :skip
    end
  end

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
