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

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to
  suppress just one kind (`c:Mutare.Mutator.variants/0`): `zero`, `succ`, `pred`, `negate`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutator.Mutation
  alias Mutare.Mutators.Helpers

  @impl Mutare.Mutator
  def name, do: :literal

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}) when is_integer(n), do: Helpers.numeric_mutations(n, 1, 0)

  def mutate({:__block__, _meta, [b]}) when is_boolean(b),
    do: [Mutation.tagged(AST.literal(not b), "negate")]

  def mutate(_node), do: :skip

  # Variant vocabulary for `# mutare:ignore[literal:<label>]`: the *semantic kind* of the change,
  # not the resulting value (which is unbounded). `succ` = `n + 1`, `pred` = `n - 1`, `zero` = the
  # `0` sentinel (the three tagged by `Helpers.numeric_mutations/3` at production), `negate` = the
  # boolean flip (tagged above). The label(s) ride on each `Mutare.Mutator.Mutation` rather than
  # being re-derived — when the off-by-one collapses *onto* `0` (`n = 1` ⇒ `n - 1 = 0`), that one
  # deduped mutant carries *both* `pred` and `zero`, so either qualifier suppresses it.
  @impl Mutare.Mutator
  def variants, do: ~w(zero succ pred negate)
end
