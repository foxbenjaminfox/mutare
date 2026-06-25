defmodule Mutare.Mutators.CollectionArity do
  @moduledoc """
  Arity-*changing* call mutations — drop a refining argument (or collapse to a
  coarser operation), turning a discriminating call into a blunter one. Each asks
  directly: does the refinement — a comparator, key function, predicate, or update
  function — actually matter to any test?

    * `Enum.sort/1`            → `Enum.reverse/1`     — reorder differently
    * `Enum.sort/2`            → `Enum.reverse/1`     — drop the comparator
    * `Enum.reverse/1`         → `Enum.sort/1`
    * `Enum.sort_by/2`         → `Enum.reverse/1`     — drop the key function
    * `Enum.sort_by/3`         → `Enum.reverse/1`     — drop key + sorter
    * `Enum.count/2`           → `Enum.count/1`       — count everything, not matches
    * `Enum.count_until/3`     → `Enum.count_until/2` — drop the predicate, keep the limit
    * `Access.get_and_update/3` → `Access.get/2`      — drop the update function,
      collapsing a read-and-write into a plain read. The result shape changes too
      (`{get, new_container}` → the bare value), so any test that destructures the
      `get_and_update` tuple kills it; one that ignores the write does not — exactly
      the "is the update path exercised?" signal.

  `Enum.reverse/2` (`reverse(list, tail)`, an unrelated operation) is deliberately
  left alone.

  On by default. The arity-changing sibling of `Mutare.Mutators.Collection`. Matches
  aliased and bare-imported calls too.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Calls

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
    case Calls.resolved_call(node) do
      {module, fun, args, rebuild} ->
        eff_arity = Mutare.Mutator.effective_arity(args, pipe_mode)

        case Map.fetch(@rules, {module, fun, eff_arity}) do
          {:ok, {new_fun, keep}} ->
            # `rebuild` reuses the written alias node (every rule stays within `Enum`).
            [rebuild.(new_fun, kept_visible_args(args, keep, pipe_mode))]

          :error ->
            :skip
        end

      nil ->
        :skip
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
