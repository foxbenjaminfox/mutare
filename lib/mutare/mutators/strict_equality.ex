defmodule Mutare.Mutators.StrictEquality do
  @moduledoc """
  Relaxes strict equality without changing polarity:

    * `a === b` → `a == b`
    * `a !== b` → `a != b`

  The reverse replacements are not produced. This family checks whether the numeric type distinction made by strict equality is required.

  `Mutare.Mutators.Relational` independently changes equality polarity, such as `===` to `!==`. Both families may therefore produce distinct mutants at the same expression. Under `not` or `!`, relational polarity changes may overlap with a logical mutation and be suppressed; strictness relaxation remains distinct and is retained.

  These operators are guard-safe and are also mutated in guards. The ignore variants are `==` and `!=`.
  """
  @behaviour Mutare.Mutator

  # One-direction relaxation only: strict → loose. The loose operators (`==`/`!=`) are
  # deliberately absent — they are never tightened here.
  @swaps %{
    :=== => :==,
    :!== => :!=
  }

  @impl Mutare.Mutator
  def name, do: :strict_equality

  @impl Mutare.Mutator
  def mutate({op, meta, [left, right]}) when is_map_key(@swaps, op) do
    [{Map.fetch!(@swaps, op), meta, [left, right]}]
  end

  def mutate(_node), do: :skip

  # Variant labels for `# mutare:ignore[strict_equality:<op>]`: the relaxed operator
  # (`===` → `==`, `!==` → `!=`). Both sets derive from `@swaps` (the mutate table): the *result*
  # operators are the labels, and the classifier's operator set is sources + results together, so
  # the shared `op_swap_variant/3` (the one home for the operator-family `variant/2` shape) can map
  # a `===` → `==` pair to `"=="` just like the other operator families. Single-sourced from
  # `@swaps`, so vocabulary, classifier, and swaps can't drift.
  @result_ops Map.values(@swaps)
  @swap_ops Map.keys(@swaps) ++ @result_ops

  @impl Mutare.Mutator
  def variants, do: Enum.map(@result_ops, &to_string/1)

  @impl Mutare.Mutator
  def variant(original, mutated), do: Mutare.Mutator.op_swap_variant(original, mutated, @swap_ops)
end
