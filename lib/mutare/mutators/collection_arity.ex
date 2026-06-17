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
  `Mutare.Transform` invokes with `%{piped: boolean}` at each runtime call site:
  `effective_arity = length(args) + if(piped, do: 1, else: 0)`. That makes every case
  correct — including skipping `Enum.reverse/2` (`reverse(list, tail)`, an unrelated
  operation) whether or not it's written in a pipe.

  ## Compile- and guard-safety

  Every result reuses the surviving argument AST and only *removes* arguments (or
  renames to a function that exists at the lower arity — `reverse/1`, `sort/1`,
  `count/1`, `count_until/2` all exist), so the single metamutant build always
  compiles. `Enum` calls are never guard-legal, so guard-safety is automatic.

  On by default. The arity-changing sibling of `Mutare.Mutators.Collection`. Recognises
  `Enum` by its resolved module (`Mutare.Transform.Aliases`), so an aliased call is matched.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Aliases

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
  def mutate(
        {{:., dot_meta, [{:__aliases__, alias_meta, mod} = aliases, fun]}, call_meta, args},
        %{piped: piped?}
      )
      when is_list(args) do
    eff_arity = Mutare.Mutator.effective_arity(args, piped?)

    case Map.fetch(@rules, {Aliases.resolved_module(alias_meta, mod), fun, eff_arity}) do
      {:ok, {new_fun, keep}} ->
        new_args = kept_visible_args(args, keep, piped?)
        # Reuse the literal alias node (every rule stays within `Enum`).
        [{{:., dot_meta, [aliases, new_fun]}, call_meta, new_args}]

      :error ->
        :skip
    end
  end

  def mutate(_node, _context), do: :skip

  # Translate kept *effective* indices to the *visible* argument list. When piped,
  # effective index 0 is the `|>` left side (not in `args`), so it's omitted and the
  # remaining effective indices shift down by one.
  defp kept_visible_args(args, keep, true) do
    keep
    |> Enum.reject(&(&1 == 0))
    |> Enum.map(&Enum.fetch!(args, &1 - 1))
  end

  defp kept_visible_args(args, keep, false) do
    Enum.map(keep, &Enum.fetch!(args, &1))
  end
end
