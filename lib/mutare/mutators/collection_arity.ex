defmodule Mutare.Mutators.CollectionArity do
  @moduledoc """
  Changes collection calls to a related operation with fewer arguments:

    * `Enum.sort/1` → `Enum.reverse/1`
    * `Enum.sort/2` → `Enum.reverse/1`, dropping the comparator
    * `Enum.reverse/1` → `Enum.sort/1`
    * `Enum.sort_by/2` → `Enum.reverse/1`, dropping the key function
    * `Enum.sort_by/3` → `Enum.reverse/1`, dropping the key function and sorter
    * `Enum.count/2` → `Enum.count/1`, dropping the predicate
    * `Enum.count_until/3` → `Enum.count_until/2`, dropping the predicate but retaining the limit
    * `Access.get_and_update/3` → `Access.get/2`, dropping the update function

  The `Access` replacement also changes the result from `{value, updated_container}` to the value alone. `Enum.reverse/2` is not mutated because its second argument is a list tail rather than a sorting refinement.

  Direct, aliased, imported, and piped calls are supported. This family is enabled by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # {alias_path, function, effective_arity} => {new_function, kept_effective_indices}.
  # Every rule keeps effective index 0 (the enumerable); in a pipe that index is the
  # `|>` left side, supplied by the pipe, so it drops out of the *visible* args.
  @rules %{
    {[:Enum], :sort, 1} => {:reverse, [0]},
    {[:Enum], :sort, 2} => {:reverse, [0]},
    {[:Enum], :reverse, 1} => {:sort, [0]},
    {[:Enum], :sort_by, 2} => {:reverse, [0]},
    {[:Enum], :sort_by, 3} => {:reverse, [0]},
    {[:Enum], :count, 2} => {:count, [0]},
    {[:Enum], :count_until, 3} => {:count_until, [0, 2]},
    # `Access.get_and_update/3` → `Access.get/2`: keep the container + key (effective
    # indices 0, 1), drop the update function. `Access.get/2` exists, so it compiles.
    {[:Access], :get_and_update, 3} => {:get, [0, 1]}
  }

  @impl Mutare.Mutator
  def name, do: :collection_arity

  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}) do
    with {:ok, {new_fun, keep}, {_module, _fun, args, rebuild}} <-
           Helpers.lookup_resolved_arity(node, pipe_mode, @rules) do
      # `rebuild` reuses the written alias node (every rule stays within `Enum`).
      [rebuild.(new_fun, kept_visible_args(args, keep, pipe_mode))]
    end
  end

  # Translate kept *effective* indices to the *visible* argument list, dropping any
  # that map to the (absent) piped value — see `Mutare.Mutator.visible_index/2`.
  defp kept_visible_args(args, keep, pipe_mode) do
    keep
    |> Enum.map(&Mutare.Mutator.visible_index(&1, pipe_mode))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Enum.fetch!(args, &1))
  end
end
