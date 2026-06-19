defmodule Mutare.Transform.Overlap do
  @moduledoc false

  # Cross-mutator overlap resolution, run once over an annotated subtree just before
  # `Mutare.Transform.emit/2` assigns ids — so a dropped candidate leaves no id, site,
  # or selector (exactly like the local self-opt-out `gate_candidates/1`, and ids stay
  # contiguous across poison rebuilds).
  #
  # The problem it solves: a *call-rewriting* mutator (`Mutare.Mutators.ModeSwap`) and a
  # *leaf* mutator (`AtomLiteral`) can both target the same source node — the unit/mode
  # atom in `DateTime.truncate(dt, :second)`, or one `unit:` key of a `shift` duration.
  # ModeSwap rewrites the whole call to a sibling unit (a useful, observable mutant);
  # AtomLiteral would *also* turn that same `:second` / `minute:` into the sentinel
  # `:mutare`, an always-raising, trivially-killed, zero-signal mutant. We want the
  # call rewrite to win and the redundant leaf mutation to disappear.
  #
  # Rather than have ModeSwap *declare* the positions it owns (the old `owned_args/2`
  # callback — a second source of truth that drifted from `mutate/2` and could only speak
  # in argument positions, not keyword *keys*), ownership is **derived from the mutation
  # itself**:
  #
  #   * A candidate's *footprint* is the source range of the **minimal changed subtree**
  #     between its `original` and `mutated` nodes (`footprint/2`). A leaf swap changes the
  #     whole host (footprint == host range); a call rewrite that substitutes exactly one
  #     descendant has a footprint that is a *proper sub-range* of its host — it is
  #     **covering**.
  #   * Any **non-covering** candidate whose host range equals some covering candidate's
  #     footprint is dropped: that is precisely the redundant leaf mutation of the node the
  #     rewrite already covers.
  #
  # This is exact (distinct source nodes have distinct ranges, via `NodeRange.get/1`), at
  # node granularity (so a `shift` key ModeSwap does *not* swap — `microsecond:`, excluded
  # from its ladder — keeps its AtomLiteral mutant, consistently whether alone or beside a
  # swappable sibling), and zero-API (any future minimal-rewrite call mutator gets it for
  # free). A permuting mutator (`OperandSwap`, `a - b` → `b - a`: two children change) or an
  # arity/name-changing one (`CallRemoval`/`DefaultDrop`/`CollectionArity`) is non-covering
  # by construction, so it suppresses nothing — matching the prior behaviour.
  #
  # Scope: only `Candidate.InPlace` in the `:mutare` key. ModeSwap targets runtime call
  # arguments, never guards/patterns, so it is never lifted and never a structural/pattern
  # candidate kind; those (and `:mutare_case`) are left untouched.

  alias Mutare.Transform.{Candidate, NodeRange}

  @doc """
  Drop each non-covering `Candidate.InPlace` whose host range is covered by another
  candidate's minimal-rewrite footprint. A no-op (the tree unchanged) when no candidate is
  covering — the overwhelmingly common case (any subtree without a ModeSwap-style call).
  """
  @spec resolve(Macro.t()) :: Macro.t()
  def resolve(tree) do
    covered = covered_ranges(tree)
    if MapSet.size(covered) == 0, do: tree, else: prune(tree, covered)
  end

  # The set of covering footprints: every InPlace candidate whose rewrite touches a proper
  # descendant (footprint range present and not the host's own range).
  defp covered_ranges(tree) do
    {_tree, set} =
      Macro.prewalk(tree, MapSet.new(), fn node, acc -> {node, collect(node, acc)} end)

    set
  end

  defp collect({_form, meta, _args}, acc) when is_list(meta) do
    meta
    |> Keyword.get(:mutare, [])
    |> Enum.reduce(acc, fn
      %Candidate.InPlace{original: o, mutated: m}, acc ->
        case footprint(o, m) do
          nil -> acc
          range -> MapSet.put(acc, range)
        end

      _other, acc ->
        acc
    end)
  end

  defp collect(_node, acc), do: acc

  defp prune(tree, covered) do
    Macro.postwalk(tree, fn
      {form, meta, args} when is_list(meta) ->
        case Keyword.get(meta, :mutare) do
          nil ->
            {form, meta, args}

          cands ->
            {form, Keyword.put(meta, :mutare, Enum.reject(cands, &drop?(&1, covered))), args}
        end

      other ->
        other
    end)
  end

  # Drop only a *non-covering* candidate (its own footprint is the whole host) whose host
  # range is some covering candidate's footprint. The "non-covering" guard is what keeps a
  # covering candidate from ever being dropped (a latent footgun if a second call-rewriter
  # ever produced a footprint equal to another's host range).
  defp drop?(%Candidate.InPlace{range: range} = c, covered) do
    not is_nil(range) and MapSet.member?(covered, range) and
      footprint(c.original, c.mutated) == nil
  end

  defp drop?(_other, _covered), do: false

  # The source range of the minimal subtree that differs between `original` and `mutated`,
  # or `nil` when the *whole host* changed (a leaf swap — non-covering) or nothing changed.
  # The range is always taken from the **original** side (the mutated literal carries fresh
  # `[]` metadata, so it has no range).
  defp footprint(original, mutated) do
    case diff(original, mutated) do
      :equal -> nil
      {:diff, sub} -> if sub === original, do: nil, else: NodeRange.get(sub)
    end
  end

  # Structural diff returning `:equal` or `{:diff, minimal_original_subtree}`. Unchanged
  # subtrees are caught by `===` (the mutators reuse the original AST verbatim except the one
  # swapped node, so identity holds). Descent stops at a `{:__block__, meta, [literal]}`
  # wrapper — the rangeable node — rather than the bare value inside it (which has none).
  defp diff(o, m) do
    cond do
      o === m ->
        :equal

      scalar_wrapper?(o) and scalar_wrapper?(m) ->
        if wrapped_value(o) === wrapped_value(m), do: :equal, else: {:diff, o}

      ast_node?(o) and ast_node?(m) ->
        {of, _, oa} = o
        {mf, _, ma} = m
        reduce([{of, mf}, {oa, ma}], o)

      pair?(o) and pair?(m) ->
        {ok, ov} = o
        {mk, mv} = m
        reduce([{ok, mk}, {ov, mv}], o)

      is_list(o) and is_list(m) and length(o) == length(m) ->
        reduce(Enum.zip(o, m), o)

      true ->
        {:diff, o}
    end
  end

  # Combine child diffs: all equal → equal; exactly one differs → that (already-minimal)
  # diff; two or more differ (or shapes/arities mismatch) → this node is the minimal subtree.
  defp reduce(pairs, node) do
    case pairs |> Enum.map(fn {a, b} -> diff(a, b) end) |> Enum.reject(&(&1 == :equal)) do
      [] -> :equal
      [single] -> single
      _ -> {:diff, node}
    end
  end

  defp ast_node?(t), do: is_tuple(t) and tuple_size(t) == 3 and is_list(elem(t, 1))

  defp pair?(t), do: is_tuple(t) and tuple_size(t) == 2

  defp scalar_wrapper?({:__block__, meta, [v]}) when is_list(meta),
    do: is_atom(v) or is_number(v) or is_binary(v)

  defp scalar_wrapper?(_node), do: false

  defp wrapped_value({:__block__, _meta, [v]}), do: v
end
