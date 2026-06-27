defmodule Mutare.Mutators.FloatLiteral do
  @moduledoc """
  Float-literal mutations: `x` → `x + 1.0`, `x - 1.0`, and `0.0`, deduplicated
  and never equal to `x`.

  The float counterpart of `Mutare.Mutators.Literal`'s integer arm. On by default.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to
  suppress just one kind (`c:Mutare.Mutator.variants/0`): `zero`, `succ`, `pred`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  @impl Mutare.Mutator
  def name, do: :float

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [f]}) when is_float(f),
    do: Helpers.numeric_mutations(f, 1.0, 0.0)

  def mutate(_node), do: :skip

  # Variant labels for `# mutare:ignore[float:<label>]`: the *semantic kind* of the change —
  # `succ` = `x + 1.0`, `pred` = `x - 1.0`, `zero` = the `0.0` sentinel — mirroring
  # `Mutare.Mutators.Literal`'s integer arm (no `negate`: a float has no boolean flip). When the
  # off-by-one collapses *onto* `0.0` (`x = -1.0` ⇒ `x + 1.0 = 0.0`) the deduped mutant carries
  # *both* labels, so either qualifier suppresses it.
  @impl Mutare.Mutator
  def variants, do: ~w(zero succ pred)

  @impl Mutare.Mutator
  def variant({:__block__, _meta, [f]}, mutated) when is_float(f),
    do: Helpers.numeric_variant_labels(f, mutated, 1.0, 0.0)

  def variant(_original, _mutated), do: nil
end
