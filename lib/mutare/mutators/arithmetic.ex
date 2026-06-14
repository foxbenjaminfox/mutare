defmodule Mutare.Mutators.Arithmetic do
  @moduledoc """
  Arithmetic operator swaps: `+`↔`-`, `*`↔`/`, `div`↔`rem`.

  In-place and compile-safe by construction — swapping one binary arithmetic
  operator for another always type-checks at compile time.

  ## Multiplicative identity is skipped

  `a * 1` and `a / 1` are skipped — swapping `*`↔`/` there leaves the value
  unchanged, so the mutant would be equivalent and only inflate the score's
  denominator. Only the **right** operand qualifies: `1 * a` → `1 / a` is a
  reciprocal, a real change.

  Caveat (rare, `==`-invisible): `/` always yields a float, so for integer `a`,
  `a * 1` and `a / 1` differ in *type* — equal under `==`, not under `===`. We
  treat that as equivalent for scoring.

  ## Additive identity is NOT skipped

  We deliberately keep `a + 0` and `a - 0` as mutants. Adding/subtracting a
  literal zero has one genuine, test-observable use: normalizing floating-point
  negative zero (`x + 0.0` turns `-0.0` into `0.0`, but `x - 0.0` keeps it). If
  an author writes that on purpose, the `+`↔`-` mutant is precisely the check
  that they actually test the result — so we surface it rather than hide it.

  `div`/`rem` are never identities either: `div(a, 1)` is `a`, but `rem(a, 1)`
  is always `0`.
  """
  @behaviour Mutare.Mutator

  @swaps %{
    :+ => [:-],
    :- => [:+],
    :* => [:/],
    :/ => [:*],
    :div => [:rem],
    :rem => [:div]
  }

  # operator => right-operand value that makes the swap an equivalent no-op
  @identity %{:* => 1, :/ => 1}

  @impl Mutare.Mutator
  def name, do: :arithmetic

  @impl Mutare.Mutator
  def mutate({op, meta, [left, right]}) do
    case Map.fetch(@swaps, op) do
      {:ok, replacements} ->
        if identity_swap?(op, right) do
          :skip
        else
          Enum.map(replacements, &{&1, meta, [left, right]})
        end

      :error ->
        :skip
    end
  end

  def mutate(_node), do: :skip

  defp identity_swap?(op, right) do
    case Map.fetch(@identity, op) do
      {:ok, identity} -> literal_value(right) == identity
      :error -> false
    end
  end

  defp literal_value(value) when is_number(value), do: value
  defp literal_value({:__block__, _meta, [value]}) when is_number(value), do: value
  defp literal_value(_node), do: :not_a_literal
end
