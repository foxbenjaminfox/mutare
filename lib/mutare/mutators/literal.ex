defmodule Mutare.Mutators.Literal do
  @moduledoc """
  Constant mutations on integer and boolean literals:

    * integers — `n` → `n + 1`, `n - 1`, and `0` (the "off-by-one" boundary plus
      the zero sentinel), deduplicated and never equal to `n`
    * booleans — `true` ↔ `false`

  Only literals in *runtime* positions are mutated, never pattern literals.
  Mutations that would reproduce the original value are dropped (`0` is not
  re-emitted for the literal `0`; `n - 1` and `0` collapse for `n = 1`).

  Integer literals are pervasive, so this is the highest-volume built-in — the
  cost is paid in the denominator, the benefit is catching constants the suite
  never pins down.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.Helpers

  @impl Mutare.Mutator
  def name, do: :literal

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}) when is_integer(n), do: Helpers.numeric_mutations(n, 1, 0)

  def mutate({:__block__, _meta, [b]}) when is_boolean(b), do: [AST.literal(not b)]

  def mutate(_node), do: :skip

  # Variant labels for `# mutare:ignore[literal:<label>]`: the *semantic kind* of the change,
  # not the resulting value (which is unbounded). `succ` = `n + 1`, `pred` = `n - 1`,
  # `zero` = the `0` sentinel, `negate` = the boolean flip. Classified by value relationship.
  # When the off-by-one collapses *onto* `0` (the merged mutant: `n = 1` ⇒ `n - 1 = 0`,
  # `n = -1` ⇒ `n + 1 = 0`), the single deduped mutant is **both** kinds — so it carries *both*
  # labels and `[literal:pred]` *and* `[literal:zero]` each suppress the `1 → 0` mutant of `x - 1`,
  # whichever way the user reasons about it. A non-collapsing mutant carries exactly one label.
  @impl Mutare.Mutator
  def variants, do: ~w(zero succ pred negate)

  @impl Mutare.Mutator
  def variant({:__block__, _m, [n]}, mutated) when is_integer(n) do
    # `int_value/1` yields the mutated integer (or `:error`, which equals none of the targets, so
    # the comprehension is empty). A mutated value can satisfy more than one relationship at once
    # (`0` is both `n - 1` and the zero sentinel when `n = 1`), so collect *every* matching label.
    m = int_value(mutated)

    for {applies?, label} <- [{m == n + 1, "succ"}, {m == n - 1, "pred"}, {m == 0, "zero"}],
        applies?,
        do: label
  end

  def variant({:__block__, _m, [b]}, _mutated) when is_boolean(b), do: "negate"
  def variant(_original, _mutated), do: nil

  # The integer value of a literal mutated node. The negative `{:-, _, [literal]}` form
  # `AST.literal/1` emits for negatives is unwrapped here (it is outside `AST.literal_value/1`'s
  # scalar-literal contract); the base case defers to `AST.literal_value/1`. `:error` otherwise.
  defp int_value({:-, _m, [inner]}), do: negate(int_value(inner))

  defp int_value(node) do
    case AST.literal_value(node) do
      {:ok, v} when is_integer(v) -> v
      _ -> :error
    end
  end

  defp negate(:error), do: :error
  defp negate(v), do: -v
end
