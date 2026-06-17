defmodule Mutare.Mutators.Literal do
  @moduledoc """
  Constant mutations on integer and boolean literals:

    * integers — `n` → `n + 1`, `n - 1`, and `0` (the "off-by-one" boundary plus
      the zero sentinel), deduplicated and never equal to `n`
    * booleans — `true` ↔ `false`

  In-place and compile-safe by construction — a literal is legal wherever it
  already appears (including patterns? no: the transform only offers a literal to
  a mutator in a *runtime* position, so pattern literals are never mutated).

  ## Why a clean-meta `{:__block__, [], [value]}`

  Sourceror parses every literal as `{:__block__, meta, [value]}` and renders it
  back from a `:token` string captured in `meta` — so reusing the original meta
  would render the *original* text (`token: "1"` prints `1`) even after we change
  the value, silently producing an equivalent no-op mutant. We therefore emit the
  replacement with fresh metadata so it renders from the new value.

  ## Equivalence

  Mutations that would reproduce the original value are dropped (`0` is not
  re-emitted for the literal `0`; `n - 1` and `0` collapse for `n = 1`). Integer
  literals are pervasive, so this is the highest-volume built-in — the cost is
  paid in the denominator, the benefit is catching constants the suite never
  pins down.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :literal

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}) when is_integer(n) do
    [n + 1, n - 1, 0]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == n))
    |> Enum.map(&AST.literal/1)
  end

  def mutate({:__block__, _meta, [b]}) when is_boolean(b), do: [AST.literal(not b)]

  def mutate(_node), do: :skip
end
