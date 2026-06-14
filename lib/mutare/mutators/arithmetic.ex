defmodule Mutare.Mutators.Arithmetic do
  @moduledoc """
  Arithmetic operator swaps: `+`↔`-`, `*`↔`/`, `div`↔`rem`.

  In-place and compile-safe by construction — swapping one binary arithmetic
  operator for another always type-checks at compile time.

  ## Identity operands are skipped

  When the **right** operand is the operator pair's identity element, the swap
  produces a value equal to the original, so we emit no mutant — an equivalent
  mutant can never be killed and only inflates the score's denominator:

    * `a * 1` → `a / 1`  and  `a / 1` → `a * 1`  (multiplicative identity)
    * `a + 0` → `a - 0`  and  `a - 0` → `a + 0`  (additive identity)

  Only the *right* operand qualifies. `1 * a` → `1 / a` is a reciprocal and
  `0 - a` → `0 + a` flips a sign — both real changes. And `div`/`rem` are never
  skipped: `div(a, 1)` is `a` but `rem(a, 1)` is always `0`.

  Two caveats, both rare and invisible to `==`:

    * `*`/`/`: for integer `a`, `a * 1` and `a / 1` differ in *type* (`/` always
      yields a float) — equal under `==`, not under `===`.
    * `+`/`-`: `a + 0` and `a - 0` differ only when `a` is `-0.0`
      (`-0.0 + 0 == 0.0` vs `-0.0 - 0 == -0.0`), and even then they compare equal.
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

  # operator => right-operand value that makes the swap an identity (no-op)
  @identity %{:* => 1, :/ => 1, :+ => 0, :- => 0}

  @impl Mutare.Mutator
  def name, do: :arithmetic

  @impl Mutare.Mutator
  def kind, do: :in_place

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
