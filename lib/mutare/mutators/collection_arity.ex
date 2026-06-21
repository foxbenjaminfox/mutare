defmodule Mutare.Mutators.CollectionArity do
  @moduledoc """
  Arity-*changing* `Enum` call mutations — drop a refining argument (or collapse to
  a coarser operation), turning a discriminating call into a blunter one. Each asks
  directly: does the refinement — a comparator, key function, or predicate —
  actually matter to any test?

    * `Enum.sort/1`        → `Enum.reverse/1`     — reorder differently
    * `Enum.sort/2`        → `Enum.reverse/1`     — drop the comparator
    * `Enum.reverse/1`     → `Enum.sort/1`
    * `Enum.sort_by/2`     → `Enum.reverse/1`     — drop the key function
    * `Enum.sort_by/3`     → `Enum.reverse/1`     — drop key + sorter
    * `Enum.count/2`       → `Enum.count/1`       — count everything, not matches
    * `Enum.count_until/3` → `Enum.count_until/2` — drop the predicate, keep the limit

  ## Why this is pipe-aware (and `Collection` isn't)

  `Collection` is a pure, arity-*blind* rename: it keeps the argument list verbatim,
  so it's correct at any arity, piped or not. These mutations change a call's arity,
  so they need its **effective** arity — and that is ambiguous from the node alone in
  a pipe, because Elixir expands `|>` only after this transform runs, so a stage's
  node carries one fewer argument than the source reads (the piped value is the `|>`
  left side). `xs |> Enum.sort(:desc)` reaches a mutator as a 1-arg `Enum.sort(:desc)`,
  indistinguishable from a non-piped `Enum.sort(list)`.

  So this family implements the optional `mutate/2` callback (never `mutate/1`), which
  `Mutare.Transform` invokes with `%{pipe_mode: :piped | :unpiped}` at each runtime call
  site, recovering the effective arity with `effective_arity/2` (`length(args)`, plus one
  when `:piped`). That makes every case
  correct — including skipping `Enum.reverse/2` (`reverse(list, tail)`, an unrelated
  operation) whether or not it's written in a pipe.

  ## Compile- and guard-safety

  Every result reuses the surviving argument AST and only *removes* arguments (or
  renames to a function that exists at the lower arity — `reverse/1`, `sort/1`,
  `count/1`, `count_until/2` all exist), so the single metamutant build always
  compiles. `Enum` calls are never guard-legal, so guard-safety is automatic.

  On by default. The arity-changing sibling of `Mutare.Mutators.Collection`. Recognises
  `Enum` by its resolved module (`Mutare.Transform.Calls`), so an aliased or bare-imported
  call is matched.
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
    {[:Enum], :count_until, 3} => {:count_until, [0, 2]}
  }

  @impl Mutare.Mutator
  def name, do: :collection_arity

  # Never fires node-locally: the effective arity isn't knowable without pipe
  # context, so all the work is in the pipe-aware `mutate/2`.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

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

  def mutate(_node, _context), do: :skip

  # Translate kept *effective* indices to the *visible* argument list, dropping any
  # that map to the (absent) piped value — see `Mutare.Mutator.visible_index/2`.
  defp kept_visible_args(args, keep, pipe_mode) do
    keep
    |> Enum.map(&Mutare.Mutator.visible_index(&1, pipe_mode))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Enum.fetch!(args, &1))
  end
end
