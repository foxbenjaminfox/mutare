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

  # Variant vocabulary for `# mutare:ignore[float:<label>]`: `succ` = `x + 1.0`, `pred` = `x - 1.0`,
  # `zero` = the `0.0` sentinel — mirroring `Mutare.Mutators.Literal`'s integer arm (no `negate`: a
  # float has no boolean flip). The labels are tagged at production by `Helpers.numeric_mutations/3`
  # (so there is no `variant/2` to re-derive them); a collapse onto `0.0` (`x = -1.0`) carries both.
  @impl Mutare.Mutator
  def variants, do: ~w(zero succ pred)
end
