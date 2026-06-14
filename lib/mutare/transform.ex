defmodule Mutare.Transform do
  @moduledoc """
  Source → metamutant transform (M1: in-place selector only).

  Every operator site the mutators recognise is wrapped in a tail-position
  `case` that reads the active mutant id from `:persistent_term`:

      # source:   total >= threshold
      case :persistent_term.get(:mutare_active, 0) do
        17 -> total > threshold     # mutant 17:  >= → >
        18 -> total < threshold     # mutant 18:  >= → <
        _  -> total >= threshold    # baseline + every other mutant
      end

  One `case` per site, one clause per mutant, the original in the catch-all so
  the baseline (and every non-matching id) runs unchanged.

  ## Nesting and tail position

  We rewrite the AST in place and render the result with `Sourceror.to_string`.
  Substituting a node with a `case` that yields the same value keeps whatever
  position the node held — so a site in tail position stays a tail call (LCO is
  preserved) without any special handling.

  Nested sites (e.g. `a + b > c`) are handled by putting the *transformed*
  children in the catch-all branch: when an outer mutant is inactive, control
  falls through to the catch-all and any inner selector is still reachable.
  The mutant branches reuse the original (untransformed) operands — sound
  because exactly one mutant is ever active, so inner selectors in a mutant
  branch would take their own baseline anyway.

  Ranges are captured against the *original* AST and refer to original-source
  coordinates, which is what the diff report patches against.
  """

  alias Mutare.Site

  @default_mutators [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]
  @selector_key Mutare.Selector.key()
  @baseline Mutare.Selector.baseline()

  @doc """
  Transform a source string into `{metamutant_source, [%Site{}]}`.

  Options:

    * `:file` — path recorded on each site (default `"nofile"`)
    * `:mutators` — list of mutator modules (default arithmetic + relational)
    * `:start_id` — first mutant id to assign (default `1`)
  """
  @spec transform_string(String.t(), keyword()) :: {String.t(), [Site.t()]}
  def transform_string(source, opts \\ []) when is_binary(source) do
    file = Keyword.get(opts, :file, "nofile")
    mutators = Keyword.get(opts, :mutators, @default_mutators)
    start_id = Keyword.get(opts, :start_id, 1)

    quoted = Sourceror.parse_string!(source)
    ranges = capture_ranges(quoted, mutators)

    {mutated_ast, {_next_id, sites_rev}} =
      Macro.postwalk(quoted, {start_id, []}, fn node, {id, sites} = acc ->
        case Map.fetch(ranges, node_key(node)) do
          {:ok, %{range: range, node: original_node}} ->
            wrap_site(node, original_node, range, file, mutators, id, sites)

          :error ->
            {node, acc}
        end
      end)

    metamutant =
      mutated_ast
      |> normalize_do_blocks()
      |> Sourceror.to_string()

    {metamutant, Enum.reverse(sites_rev)}
  end

  # --- internals -----------------------------------------------------------

  # Sourceror represents a keyword-style block (`def f, do: x`) as
  # `{{:__block__, [format: :keyword], [:do]}, body}`. The formatter cannot
  # render such a block when its body becomes a multi-line `case`, so we flip
  # every do-family keyword block to plain block form before rendering. This
  # only affects the throwaway metamutant; the diff report patches the original
  # source, so author-facing formatting is untouched.
  defp normalize_do_blocks(ast) do
    Macro.prewalk(ast, fn
      {{:__block__, _meta, [kw]}, value} when kw in [:do, :else, :catch, :rescue, :after] ->
        {kw, value}

      other ->
        other
    end)
  end

  # First pass over the untouched AST: record each site's source range, keyed by
  # its (line, column) so we can recover it in the post-pass after children have
  # been rewritten.
  defp capture_ranges(quoted, mutators) do
    {_ast, ranges} =
      Macro.prewalk(quoted, %{}, fn node, acc ->
        if site?(node, mutators) do
          {node, Map.put(acc, node_key(node), %{range: Sourceror.get_range(node), node: node})}
        else
          {node, acc}
        end
      end)

    ranges
  end

  defp wrap_site(node, original_node, range, file, mutators, id, sites) do
    {clauses, new_sites, next_id} =
      original_node
      |> mutations(mutators)
      |> Enum.reduce({[], sites, id}, fn {mutator, mutated_node}, {clauses, sites, cur_id} ->
        site = build_site(cur_id, file, range, original_node, mutated_node, mutator)
        clause = {:->, [], [[cur_id], mutated_node]}
        {[clause | clauses], [site | sites], cur_id + 1}
      end)

    case_node = build_case(node, Enum.reverse(clauses))
    {case_node, {next_id, new_sites}}
  end

  defp build_site(id, file, range, original_node, mutated_node, mutator) do
    {original_op, _, _} = original_node
    {mutated_op, _, _} = mutated_node

    %Site{
      id: id,
      file: file,
      line: range.start[:line],
      column: range.start[:column],
      range: range,
      mutator: mutator.name(),
      original_op: original_op,
      mutated_op: mutated_op,
      original_code: Sourceror.to_string(original_node),
      mutated_code: Sourceror.to_string(mutated_node),
      original_node: original_node,
      mutated_node: mutated_node
    }
  end

  # case :persistent_term.get(:mutare_active, 0) do
  #   <id> -> <mutated> ; ... ; _ -> <default>
  # end
  defp build_case(default_node, mutant_clauses) do
    selector =
      {{:., [], [:persistent_term, :get]}, [], [@selector_key, @baseline]}

    catch_all = {:->, [], [[{:_, [], nil}], default_node]}
    {:case, [], [selector, [do: mutant_clauses ++ [catch_all]]]}
  end

  defp mutations(node, mutators) do
    Enum.flat_map(mutators, fn mutator ->
      case mutator.mutate(node) do
        :skip -> []
        nodes when is_list(nodes) -> Enum.map(nodes, &{mutator, &1})
      end
    end)
  end

  defp site?(node, mutators), do: mutations(node, mutators) != []

  defp node_key({_op, meta, _args}) when is_list(meta),
    do: {Keyword.get(meta, :line), Keyword.get(meta, :column)}

  defp node_key(_), do: nil
end
