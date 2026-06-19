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
  # free).
  #
  # ## What is "covering", precisely — and what each mutator does
  #
  # Covering hinges on the *minimal changed subtree being a proper, **rangeable** descendant*
  # of the host. Three shapes arise across the built-ins:
  #
  #   * **ModeSwap** — substitutes one rangeable literal arg/key (`:second`,`minute:`). The
  #     footprint is that literal, which AtomLiteral *also* hosts → the **only suppression
  #     that actually fires**.
  #   * **Operator swaps / function renames** (Arithmetic, Relational, Logical, Collection,
  #     StringCall, Numeric, …) — change a bare **form/name atom** (`:+`, the `fun` in a
  #     `{:., _, [mod, fun]}`). Bare atoms in form position carry *no* metadata, so
  #     `NodeRange.get/1` returns `nil` → **non-covering** (this is the load-bearing
  #     property — see the sharp edge below). A whole-node replacement (a literal family, a
  #     boolean→`true`, `String.equivalent?`→`==`) likewise differs at the host → `nil`.
  #   * **Arity changes** (DefaultDrop, CollectionArity, CallRemoval's arg-drop) — the
  #     differing subtree is the whole **argument list**, which *is* rangeable and (inside the
  #     parens) a *proper sub-range* of the call, so these are technically **covering** and
  #     their args-list range lands in `covered_ranges`. They suppress nothing only because no
  #     *single* leaf candidate's host equals a whole args-list range. So `covered_ranges` is
  #     routinely non-empty (any `Map.get/3`, `Enum.sort/2`, …) and the prune pass does run —
  #     it just finds no match.
  #   * **Operand permutation** (`OperandSwap`, `a - b` → `b - a`) — also changes the argument
  #     list, but for an **infix** operator Sourceror ranges `[a, b]` *identically* to the whole
  #     `a - b` node. So its footprint range equals the host range → **non-covering** (the
  #     proper-sub-range test in `footprint/3`). This is essential: otherwise it would prune the
  #     `Arithmetic` `a - b` → `a + b` (and `List` `++`↔`--`) sibling, whose host shares that
  #     range. The *call* forms (`div(a, b)`, `DateTime.compare(a, b)`) range their args inside
  #     the parens, so they are covering-but-harmless like the arity changes above.
  #
  # So: several built-ins are "covering" in the mechanical sense, but ModeSwap→AtomLiteral is
  # the only overlap that resolves to a real drop.
  #
  # ## Sharp edge (latent)
  #
  # The "args-list footprint matches no single leaf" guarantee holds for *today's* mutators
  # but is not airtight. A bare single-element args list (`foo(0)` → args `[0]`) has the
  # *same* range as its lone element, so a hypothetical mutator dropping a call from arity 1
  # to 0 on a **literal** argument would produce an args-list footprint equal to that
  # literal's range — and wrongly suppress its leaf mutation. No built-in does an arity-1→0
  # drop on a literal, so this never triggers; flagged here for whoever adds one. (The
  # `nil`-footprint shield for operator/name atoms is likewise contingent on Sourceror not
  # ranging bare form-position atoms.)
  #
  # Scope: only `Candidate.InPlace` in the `:mutare` key. ModeSwap targets runtime call
  # arguments, never guards/patterns, so it is never lifted and never a structural/pattern
  # candidate kind; those (and `:mutare_case`) are left untouched.

  alias Mutare.Transform.{Candidate, NodeRange}

  @doc """
  Drop each non-covering `Candidate.InPlace` whose host range is covered by another
  candidate's minimal-rewrite footprint. The footprint scan always runs (it is O(1) per leaf
  candidate); the *prune* postwalk is skipped when nothing is covering, leaving the tree
  unchanged. Covering candidates are common (any arity-changing call), but only
  ModeSwap→AtomLiteral resolves to an actual drop — see the moduledoc.
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
      %Candidate.InPlace{original: o, mutated: m, range: host_range}, acc ->
        case footprint(o, m, host_range) do
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
      footprint(c.original, c.mutated, range) == nil
  end

  defp drop?(_other, _covered), do: false

  # The source range of the minimal subtree that differs between `original` and `mutated`,
  # **only when it is a proper sub-range of the host** (`host_range`) — i.e. the rewrite
  # touched a genuine descendant. `nil` otherwise: nothing changed, the changed subtree is
  # unrangeable (an operator/function-name atom), or its range *equals* the host range.
  #
  # That last clause is load-bearing. A structural-identity test (`sub === original`) is not
  # enough: an `OperandSwap` (`a - b` → `b - a`) changes the *argument list* `[a, b]`, which
  # is a different term from the infix node but which Sourceror ranges **identically** to it.
  # Without the range comparison that footprint would be marked covering and would prune the
  # `Arithmetic` `a - b` → `a + b` sibling (same host range). Comparing ranges — a descendant's
  # range is always within the host's, so "not equal" means "strictly inside" — keeps such a
  # whole-host rewrite non-covering. The range is taken from the **original** side (the mutated
  # literal carries fresh `[]` metadata, so it has no range).
  defp footprint(original, mutated, host_range) do
    case diff(original, mutated) do
      :equal ->
        nil

      {:diff, sub} ->
        sub_range = NodeRange.get(sub)
        if sub_range && sub_range != host_range, do: sub_range, else: nil
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
