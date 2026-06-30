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

    * `>`, `>=`, `<`, and `<=`, because `Mutare.Mutators.Relational` already
      produces the equivalent direction change
    * commutative operators such as `+`, `*`, equality, and boolean operators
    * `in`, because the swapped right operand may not be enumerable
    * `=` and `|>`, whose operands have different roles

  ## Calls

  The first two arguments are exchanged in these calls:

    * `before?/2`, `after?/2`, `compare/2`, and `diff/2,3` on `DateTime`, `Date`,
      `Time`, and `NaiveDateTime`, where those functions exist
    * `Version.compare/2`
    * `MapSet.difference/2` and `MapSet.subset?/2`

  A trailing unit in `diff/3` is retained and may be mutated separately by
  `Mutare.Mutators.ModeSwap`.

  Aliased and imported calls are supported. An alias that resolves to another module
  does not match.

  ## Skipped cases

  Identical operands are not swapped. Piped calls are skipped because their first
  operand is supplied outside the call node. Unary minus has no second operand and is
  handled by `Mutare.Mutators.Arithmetic`.

  Guard-safe operators and calls are also mutated in guards.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers
  alias Mutare.Transform.Calls

  # The non-commutative binary *operators* whose operands we transpose. Always written
  # infix (arity 2, never piped), so the context-free helper can handle them. The
  # call-form `div`/`rem` are handled in `mutate/2` (they need the effective-arity
  # safeguard), which explicitly composes the context-free helper.
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

  # Compose the ordinary operator transpositions with the context-aware call transpositions
  # explicitly. Dispatch prefers `mutate/2` when it is exported, so mixed families make this
  # choice locally rather than relying on hidden double-dispatch.
  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}),
    do: Helpers.combine_mutations(mutate(node), contextual_mutate(node, pipe_mode))

  # `div`/`rem`: bare `Kernel` calls. Transpose only a direct, non-piped two-argument
  # call — that is exactly effective arity 2 (the bare-`Kernel` safeguard from `Numeric`,
  # confirming the builtin over a same-named user `div/3`), and the only form that holds
  # both operands. A piped `x |> div(b)` supplies its first operand from the pipe, so
  # there is nothing local to transpose; effective arity 2 there has only one visible arg,
  # which fails the `[left, right]` match and is skipped.
  defp contextual_mutate({op, meta, [left, right] = args}, :unpiped)
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
  defp contextual_mutate(node, :unpiped) do
    with {module, fun, [a, b | rest], rebuild} <- Calls.resolved_call(node),
         true <- MapSet.member?(@remote_swaps, {module, fun}),
         false <- same?(a, b) do
      [rebuild.(fun, [b, a | rest])]
    else
      _ -> :skip
    end
  end

  # A piped stage holds only one local operand (its first comes from the pipe), so there is
  # nothing to transpose — skip it. Matched explicitly as `:piped` (not a `_context`
  # wildcard) so an unrecognised pipe mode raises a FunctionClauseError rather than
  # silently skipping.
  defp contextual_mutate(_node, :piped), do: :skip

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
