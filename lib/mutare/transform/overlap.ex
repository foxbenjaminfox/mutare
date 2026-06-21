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
  #   * A candidate's *footprint* is the **minimal changed subtree** between its `original`
  #     and `mutated` nodes (a meta-insensitive lockstep diff). A leaf swap changes the
  #     whole host (footprint *is* the host); a call rewrite that substitutes exactly one
  #     descendant has a footprint that is a *proper descendant* of its host — it is
  #     **covering**.
  #   * Any **non-covering** candidate whose host is some covering candidate's footprint is
  #     dropped: that is precisely the redundant leaf mutation of the node the rewrite
  #     already covers.
  #
  # ## How "the same node" is recognised — node identity, not range
  #
  # The leaf candidate's *host* (the `:second` node carrying AtomLiteral) and the call
  # rewrite's *footprint* (the `:second` subtree inside ModeSwap's `original`) are the **same
  # source node** — but they are not `===`: `analyze` adds a `:mutare` key to the host's meta
  # after ModeSwap captured its un-annotated copy. The two are bridged by a stable per-node
  # token `meta[:mutare_nid]`, stamped once by `Mutare.Transform.Resolve` *before* `analyze`
  # runs and carried unchanged through annotation. `Resolve.nid/1` reads it; nodes with equal
  # nids are the same source node, full stop.
  #
  # This is **injective**, which `Sourceror.get_range/1` is not: distinct AST terms can share a
  # range (`[a, b]` ≡ `a - b`; a one-element call-arg list `[0]` ≡ its element `0`), and a
  # previous range-based version of this pass needed a denylist of three such collision shapes
  # (unrangeable form atoms, whole-host equality, list-valued footprints) plus two unproven
  # Sourceror invariants to stay correct. Node identity dissolves all of that: see "What is
  # covering" below for how each old denylist case falls out of "no metadata → no nid".
  #
  # The recognition still relies on a covering mutant being "the original with one subtree
  # replaced". `Mutare.Transform.Calls` upholds that for **bare imported calls**: a value-only
  # swap keeps the call bare (same name/arity) rather than requalifying it
  # (`Elixir.Mod.fun(...)`), so the diff stays single-node. If it requalified, the form *and*
  # the argument would change → two changes → a whole-host footprint → the leaf would wrongly
  # resurface (see NOTES "Overlap resolution").
  #
  # ## What is "covering", precisely — and what each mutator does
  #
  # Covering hinges on the minimal changed subtree being a *proper, **nid-bearing** descendant*
  # of the host. Exactly **one** built-in mutation produces one:
  #
  #   * **ModeSwap** — substitutes one literal arg/key (`:second`,`minute:`). The footprint is
  #     that literal's `{:__block__, _, [atom]}` wrapper, which carries a nid *and* is where
  #     AtomLiteral hosts its candidate → the **only covering footprint, and it always resolves to
  #     a drop** (the redundant AtomLiteral leaf on that arg/key is suppressed).
  #
  # Everything else is non-covering, and node identity is *why* — no extra rules needed:
  #
  #   * **Operator swaps / function renames** (Arithmetic, Relational, Logical, Collection,
  #     StringCall's renames, Numeric, …) — change a bare **form/name atom** (`:+`, the `fun` in a
  #     `{:., _, [mod, fun]}`). A bare atom carries no metadata, so it has **no nid** →
  #     non-covering. (Previously this rested on Sourceror returning `nil` for such atoms; now it
  #     is structural — atoms simply cannot be stamped.)
  #   * **Cross-module call substitutions** (`String.equivalent?(a, b)` → `Elixir.Kernel.==(a, b)`,
  #     both the direct and piped forms) — change **both** the module *and* the fun of the
  #     `{:., _, [mod, fun]}` callee while reusing the args, so the two changes climb to their
  #     common parent: the callee's `[mod, fun]` **list**. A list carries no metadata → **no nid**
  #     → non-covering, so the reused args keep their own leaf mutants (a literal `"x"` in
  #     `String.equivalent?(a, "x")` keeps both StringLiteral mutants). The *absolute* qualifier is
  #     what lands this here: a bare `a == b` would instead replace the whole callee with one atom
  #     — a `.`-node footprint that is **covering yet inert** (its nid spans `Mod.fun`, a form
  #     position no value mutator hosts a candidate at, so it suppresses nothing anyway) — but the
  #     absolute `Elixir.Kernel.==` is required for shadow-safety (see `Mutare.Mutators.StringCall`),
  #     and changing both module and fun makes the footprint a nid-less list. Either way it prunes
  #     nothing; the list footprint is simply the more direct route to that.
  #   * **Whole-node replacements** (a literal family, a boolean→`true`) — the minimal subtree
  #     *is* the host, so footprint nid == host nid → non-covering (a leaf swap is redundant with
  #     nothing).
  #   * **Arity changes** (DefaultDrop, CollectionArity, CallRemoval's arg-drop) and **operand
  #     permutation** (`OperandSwap`, `a - b` → `b - a`) — the differing subtree is the whole
  #     **argument list** (a drop changes its length; a permutation changes ≥2 elements). A list
  #     carries no metadata → **no nid** → non-covering. This is what keeps an infix `OperandSwap`
  #     from pruning its `Arithmetic`/`List` operator-swap sibling, and a *piped* one-arg drop
  #     (`xs |> List.first(0)` → `List.first()`) from pruning the `Literal 0` mutant — both of
  #     which a range-based pass got wrong (the args list shares a range with the infix node /
  #     its lone element) and had to special-case.
  #
  # So: **ModeSwap→AtomLiteral is the only covering footprint, and the only place a leaf is ever
  # dropped** — every other built-in mutation changes a bare atom or a list (no nid), so it prunes
  # nothing.
  #
  # Scope: only `Candidate.InPlace` in the `:mutare` key. ModeSwap targets runtime call
  # arguments, never guards/patterns, so it is never lifted and never a structural/pattern
  # candidate kind; those (and `:mutare_case`) are left untouched.

  alias Mutare.Transform.{Candidate, Resolve}

  @doc """
  Drop each non-covering `Candidate.InPlace` whose host node is some other candidate's
  minimal-rewrite footprint, matched by `meta[:mutare_nid]` identity. The footprint scan always
  runs — one prewalk plus a structural diff per candidate — and the *prune* postwalk is skipped
  when nothing is covering, leaving the tree unchanged. Two built-ins produce a covering
  footprint (see the moduledoc): a mode/unit swap (which drops the redundant AtomLiteral) and the
  direct `String.equivalent?/2` → `==` rewrite (covering but inert — its `.`-node nid matches no
  candidate). So the prune postwalk runs on subtrees containing either, but only the mode/unit
  swap actually drops anything.
  """
  @spec resolve(Macro.t()) :: Macro.t()
  def resolve(tree) do
    covered = covered_nids(tree)
    if MapSet.size(covered) == 0, do: tree, else: prune(tree, covered)
  end

  # The set of covering footprints, as node ids: every InPlace candidate whose rewrite touches a
  # proper, nid-bearing descendant of its host.
  defp covered_nids(tree) do
    {_tree, set} =
      Macro.prewalk(tree, MapSet.new(), fn node, acc -> {node, collect(node, acc)} end)

    set
  end

  defp collect({_form, meta, _args}, acc) when is_list(meta) do
    meta
    |> Keyword.get(:mutare, [])
    |> Enum.reduce(acc, fn
      %Candidate.InPlace{original: o, mutated: m}, acc ->
        case footprint_nid(o, m) do
          nil -> acc
          nid -> MapSet.put(acc, nid)
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
            # mutare:ignore[map_keyword] this branch only runs when :mutare is already present, so put ≡ replace (equivalent)
            {form, Keyword.put(meta, :mutare, Enum.reject(cands, &drop?(&1, covered))), args}
        end

      other ->
        other
    end)
  end

  # Drop only a *non-covering* candidate (its footprint is the whole host — `footprint_nid` is
  # `nil`) whose host node id is some covering candidate's footprint. The "non-covering" guard is
  # what keeps a covering candidate from ever being dropped (a latent footgun if a second
  # call-rewriter ever produced a footprint equal to another's host).
  defp drop?(%Candidate.InPlace{original: o, mutated: m}, covered) do
    # `covered` holds only non-nil nids (`collect/2` filters them), so membership already
    # implies a real host nid — a nil `Resolve.nid(o)` is simply not a member, no guard needed.
    MapSet.member?(covered, Resolve.nid(o)) and footprint_nid(o, m) == nil
  end

  defp drop?(_other, _covered), do: false

  # The node id of the minimal subtree that differs between `original` and `mutated`, **only
  # when it is a genuine single-node substitution within the host** — a proper, nid-bearing
  # descendant. `nil` otherwise, in three cases that node identity unifies:
  #
  #   * **No nid** — the changed subtree is a bare operator/function-name atom (an operator swap
  #     or rename) or an argument list (an arity change / operand permutation). Neither shape
  #     carries metadata, so `Resolve.nid/1` is `nil`; nothing for a leaf mutator to be redundant
  #     with.
  #   * **Whole-host** (`sub_nid == host_nid`) — a leaf swap (the changed subtree *is* the host
  #     scalar) or a whole-node replacement. A leaf swap is redundant with nothing.
  #   * **Equal** — the mutator reused the original verbatim; no change at all.
  defp footprint_nid(original, mutated) do
    case diff(original, mutated) do
      :equal ->
        nil

      {:diff, sub} ->
        sub_nid = Resolve.nid(sub)
        if sub_nid && sub_nid != Resolve.nid(original), do: sub_nid, else: nil
    end
  end

  # Structural diff returning `:equal` or `{:diff, minimal_original_subtree}`. Unchanged
  # subtrees are caught by `===` (the mutators reuse the original AST verbatim except the one
  # swapped node, so identity holds). Descent stops at a `{:__block__, meta, [literal]}`
  # wrapper — the nid-bearing node — rather than the bare value inside it (which carries none).
  # Meta is ignored throughout (`_`), so the nid the wrapper *does* carry never makes two
  # otherwise-equal nodes diff.
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
