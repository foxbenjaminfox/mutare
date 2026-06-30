defmodule Mutare.Mutators.KeywordDelete do
  @moduledoc """
  Exchanges the two duplicate-key deletion operations for keyword lists:

    * `Keyword.delete/2` ↔ `Keyword.delete_first/2`

  `delete/2` removes every entry for a key, while `delete_first/2` removes only the
  first. There is no corresponding `Map` mutation because map keys are unique.

  Matching is restricted to effective arity two. The deprecated three-argument
  `delete` form has no three-argument `delete_first` counterpart and is not mutated.
  Piped, direct, aliased, and imported calls are supported.

  `Mutare.Mutators.CallRemoval` may separately replace `Keyword.delete` with the
  original keyword list. This family retains the call and changes its deletion
  breadth. It is enabled by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # {alias_path, function, effective_arity} => complementary function. Keyed on arity so the
  # swap only fires at /2 (`delete_first` has no /3 twin); `Helpers.lookup_resolved_arity`
  # is pipe-aware, and `rebuild` keeps the written module (the swap stays within `Keyword`).
  @rules %{
    {[:Keyword], :delete, 2} => :delete_first,
    {[:Keyword], :delete_first, 2} => :delete
  }

  @impl Mutare.Mutator
  def name, do: :keyword_delete

  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}) do
    with {:ok, new_fun, {_module, _fun, args, rebuild}} <-
           Helpers.lookup_resolved_arity(node, pipe_mode, @rules) do
      # Pure rename — keep the arguments, keep the written module.
      [rebuild.(new_fun, args)]
    end
  end
end
