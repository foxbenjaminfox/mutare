defmodule Mutare.Mutator do
  @moduledoc """
  Behaviour for mutators — pure functions over AST nodes.

  A mutator inspects a single AST node and returns either `:skip` (it does not
  apply here) or a list of mutated nodes, one per mutant it wants to generate at
  that site. Mutators **never touch source text**; the transform applies them
  uniformly via the recorded source range.

  Each returned node must reuse the original operand AST so the mutation stays
  minimal and reviewable (a one-line diff). For the M1 in-place mutators this
  means rebuilding the same call node with a different operator atom.
  """

  @doc """
  Return `:skip` when the mutator does not apply to `node`, otherwise a list of
  mutated nodes (one per mutant).
  """
  @callback mutate(Macro.t()) :: :skip | [Macro.t()]

  @doc "Short family name, used in reports (e.g. `:arithmetic`)."
  @callback name() :: atom()

  @doc """
  Placement strategy: `:in_place` (wrap the site in a runtime selector) or
  `:lifted` (duplicate the enclosing function). M1 ships `:in_place` only.
  """
  @callback kind() :: :in_place | :lifted
end
