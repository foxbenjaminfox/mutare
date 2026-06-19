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
  #   * **Arity changes** (DefaultDrop, CollectionArity, CallRemoval's arg-drop) and **operand
  #     permutation** (`OperandSwap`, `a - b` → `b - a`) — the differing subtree is the whole
  #     **argument list** (a drop changes its length; a permutation changes ≥2 of its elements).
  #     A list is never a value position a leaf mutator targets, so `footprint/3` treats any
  #     list-valued footprint as **non-covering**. This is essential in two ways it would
  #     otherwise misfire: an infix `OperandSwap` would prune the `Arithmetic`/`List`
  #     operator-swap sibling (Sourceror ranges `[a, b]` identically to `a - b`), and a *piped*
  #     one-arg drop (`xs |> List.first(0)` → `List.first()`, `[0]` ranged identically to `0`)
  #     would prune the `Literal 0` mutant. Removal/permutation is orthogonal to mutating a
  #     value, so neither should suppress anything.
  #
  # So: several built-ins reach the diff, but ModeSwap→AtomLiteral is the only overlap that is
  # ever covering — the only one that resolves to a real drop.
  #
  # This recognition relies on a covering mutant being "the original with one subtree replaced".
  # `Mutare.Transform.Calls` upholds that for **bare imported calls**: a value-only swap keeps
  # the call bare (same name/arity) rather than requalifying it (`Elixir.Mod.fun(...)`), so the
  # diff stays single-node. If it requalified, the form *and* the argument would change → a
  # whole-host footprint → the leaf would wrongly resurface (see NOTES "Overlap resolution").
  #
  # The list rule above is what makes that robust. A bare single-element args list (`foo(0)` →
  # args `[0]`) has the *same* range as its lone element, so before that rule a one-visible-arg
  # arity drop — e.g. a **piped** `xs |> List.first(0)` → `List.first()`, whose only visible arg
  # is the default — produced an args-list footprint equal to `0`'s range and wrongly pruned the
  # `Literal 0` mutant. Treating any list footprint as non-covering closes it (and the whole
  # class: piped or not, one arg or many). The remaining contingency is the `nil`-footprint
  # shield for operator/name atoms, which relies on Sourceror not ranging bare form-position
  # atoms.
  #
  # Scope: only `Candidate.InPlace` in the `:mutare` key. ModeSwap targets runtime call
  # arguments, never guards/patterns, so it is never lifted and never a structural/pattern
  # candidate kind; those (and `:mutare_case`) are left untouched.

  alias Mutare.Transform.{Candidate, NodeRange}

  @doc """
  Drop each non-covering `Candidate.InPlace` whose host range is covered by another
  candidate's minimal-rewrite footprint. The footprint scan always runs (it is O(1) per leaf
  candidate); the *prune* postwalk is skipped when nothing is covering, leaving the tree
  unchanged. In practice ModeSwap is the only covering mutator (see the moduledoc), so the
  prune runs only on subtrees that contain a mode/unit swap.
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
  # **only when it is a genuine single-node substitution within the host**. `nil` otherwise.
  # A footprint is *not* covering — returns `nil` — in three cases:
  #
  #   * **Unrangeable** (`sub_range == nil`) — the change is a bare operator/function-name
  #     atom (an operator swap or rename); nothing for a leaf mutator to be redundant with.
  #   * **Whole-host** (`sub_range == host_range`) — a leaf swap (`sub` *is* the host scalar),
  #     a whole-node replacement, or an `OperandSwap` on an **infix** operator, whose changed
  #     argument list `[a, b]` is a different term from the infix node but which Sourceror
  #     ranges *identically*. Marking these covering would prune the operator-swap sibling
  #     (`a - b` → `a + b`) on the same host range. A descendant's range is always within the
  #     host's, so "not equal" means "strictly inside".
  #   * **A list** (`is_list(sub)`) — the changed subtree is an argument/element *list*, never
  #     a value position a leaf mutator targets. This happens when an arity-changing call drops
  #     an argument (`[x]` → `[]`, `[a, b]` → `[a]`) or when ≥2 siblings change (an operand
  #     permutation). Removal/permutation is orthogonal to mutating a *value*, so it must not
  #     suppress the leaf on the surviving/dropped element — critical for a **piped** one-arg
  #     drop (`xs |> List.first(0)` → `List.first()`), where the one-element list `[0]` ranges
  #     identically to its element `0` and would otherwise prune the `Literal 0` mutant. A real
  #     substitution (ModeSwap) descends *into* a same-length list to the one changed scalar/key,
  #     so its footprint is never a list.
  #
  # The range is taken from the **original** side (the mutated literal carries fresh `[]`
  # metadata, so it has no range).
  defp footprint(original, mutated, host_range) do
    case diff(original, mutated) do
      :equal ->
        nil

      {:diff, sub} when is_list(sub) ->
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
