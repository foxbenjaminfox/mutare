defmodule Mutare.OverlapTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Candidate, Overlap, Resolve}

  # `Mutare.Transform.Overlap` drops a non-covering leaf candidate whose host node is some
  # other candidate's minimal-rewrite footprint. Two layers of coverage:
  #
  #   * The *natural* path — a real `[ModeSwap, ReturnValue]` transform — pins the load-bearing
  #     invariant that the `:mutare` meta key holds non-`InPlace` candidates (`Candidate.Return`,
  #     delivered in place at a clause tail), which the `_other` fallback in `drop?/2` and the
  #     `_other -> acc` clause in `collect/2` exist for.
  #   * The *synthetic* path — hand-built AST fed straight to `resolve/1` — pins the `diff`/
  #     `footprint_nid` machinery at mechanism level (matching the style of `resolve_test.exs`).
  #     These guards are *defensive*: no built-in mutation exercises them (a diff's reused
  #     sub-terms are caught by `===`, and a multi-child change collapses to the metadata-less
  #     args list), so they are only reachable through `resolve/1` directly.

  describe "non-`InPlace` candidates under `:mutare` (the ReturnValue invariant)" do
    test "a covering footprint does not drop a `Candidate.Return` sharing the tail node" do
      # `:second` is a ModeSwap-swappable precision, so its leaf is a covering footprint and the
      # prune postwalk runs. The clause tail `DateTime.truncate(dt, :second)` also carries two
      # `Candidate.Return`s (ReturnValue delivered in place). Those are non-`InPlace`, so the
      # `defp drop?(_other, _covered), do: false` fallback must keep them — and reaching that
      # clause at all proves `:mutare` holds `Return`. (Killing `do: false → do: true`, which
      # would reject them, and the clause_drop, which would FunctionClauseError here.)
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(dt), do: DateTime.truncate(dt, :second)
          end
          """,
          mutators: [Mutare.Mutators.ModeSwap, Mutare.Mutators.ReturnValue]
        )

      # ModeSwap covers the `:second` leaf (prune runs)…
      assert Enum.any?(sites, &(&1.mutator == :mode_swap))
      # …and the in-place ReturnValue candidates on the same tail node survive the prune.
      returns = for s <- sites, s.mutator == :return_value, do: s.mutated_code
      assert "nil" in returns
      assert ":mutare" in returns
    end

    test "the bare-module sort wrap supersedes the redundant AliasLiteral leaf" do
      # `Enum.sort(xs, Date)` → `{:desc, Date}` is a ModeSwap rewrite whose footprint is the
      # `Date` (`__aliases__`) arg — a *new* covering shape (an alias node, not a `:__block__`
      # literal wrapper). AliasLiteral would also mutate that same `Date` to the sentinel module
      # (an always-raising `UndefinedFunctionError`), so the call rewrite must suppress it.
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(xs), do: Enum.sort(xs, Date)
          end
          """,
          mutators: [Mutare.Mutators.ModeSwap, Mutare.Mutators.AliasLiteral]
        )

      assert [%{mutator: :mode_swap, mutated_code: "Enum.sort(xs, {:desc, Date})"}] = sites
      refute Enum.any?(sites, &(&1.mutator == :alias))
    end
  end

  describe "the `diff`/`footprint_nid` contract (synthetic `resolve/1` inputs)" do
    # Helpers to hand-build the AST shapes `analyze` would normally produce: a node with a
    # stable `:mutare_nid` carrying an InPlace candidate in `:mutare`.
    defp node(nid, args, cands \\ []),
      do: {:f, [mutare_nid: nid, mutare: cands], args}

    defp leaf(nid, value), do: {:__block__, [mutare_nid: nid], [value]}

    defp in_place(original, mutated),
      do: %Candidate.InPlace{mutator: :test, original: original, mutated: mutated}

    # The set of candidates surviving `resolve/1`, by their `{original, mutated}` nid pair.
    defp surviving(tree) do
      {_t, cands} =
        Macro.prewalk(tree, [], fn
          {_f, meta, _a} = n, acc when is_list(meta) ->
            {n, acc ++ Keyword.get(meta, :mutare, [])}

          n, acc ->
            {n, acc}
        end)

      for %Candidate.InPlace{original: o, mutated: m} <- cands,
          do: {Resolve.nid(o), Resolve.nid(m)}
    end

    test "a changed call is not a covering footprint: the call's own candidates survive" do
      # The shape a removal has when the same head is nested (`f(f(x))` → `f(x)`): the lockstep
      # diff bottoms out at the inner call (nid 100), a proper nid-bearing descendant. It is not
      # a leaf, so it covers nothing, and the candidate hosted on the inner call is kept.
      inner = node(100, [leaf(101, 1)])
      inner_host = node(100, [leaf(101, 1)], [in_place(inner, leaf(102, 0))])

      outer =
        node(200, [inner_host, leaf(300, :x)], [
          in_place(node(200, [inner, leaf(300, :x)]), node(200, [leaf(101, 1), leaf(300, :x)]))
        ])

      assert {100, 102} in surviving(Overlap.resolve(outer))
    end

    test "a changed leaf is a covering footprint: the leaf's own candidate is dropped" do
      swapped = in_place(node(200, [leaf(101, :a)]), node(200, [leaf(101, :b)]))

      leaf_host =
        {:__block__, [mutare_nid: 101, mutare: [in_place(leaf(101, :a), leaf(101, :z))]], [:a]}

      survivors = surviving(Overlap.resolve(node(200, [leaf_host], [swapped])))

      assert survivors == [{200, 200}]
    end

    test "a single changed variable node is recursed (its bare-atom name has no nid) — not treated as covering" do
      # A variable that a rewrite renames is no covering footprint, so a candidate hosted on it
      # survives. Two things each ensure it: `ast_node?` recurses into a variable node
      # `{:x, meta, ctx}` (its third element is a context atom, not a list), so the change
      # descends to the bare name atom, which carries no nid; and a variable is not a leaf
      # (`leaf?/1` admits literals and aliases), so it would cover nothing even as the footprint.
      var_a = {:x, [mutare_nid: 50], nil}
      var_b = {:y, [mutare_nid: 50], nil}

      # A candidate whose only changed child is the variable (a → b). Its footprint is the
      # bare name atom (`:x`), which carries no nid — so it must be non-covering.
      changer =
        in_place(node(60, [var_a, leaf(70, :keep)]), node(60, [var_b, leaf(70, :keep)]))

      # The variable node itself (nid 50) hosts a sibling whole-host candidate. It must survive
      # iff the variable footprint is NOT covering — which holds only if `ast_node?` recursed
      # *into* the variable (reaching the nid-less name atom) rather than stopping at it.
      var_host = {:x, [mutare_nid: 50, mutare: [in_place(var_a, var_b)]], nil}
      tree = node(60, [var_host, leaf(70, :keep)], [changer])

      survivors = surviving(Overlap.resolve(tree))

      assert {50, 50} in survivors
    end

    test "a 2-tuple pair is only matched against another 2-tuple (`pair?` size check)" do
      # `diff` reaches the `pair?` branch with a `{k, v}` pair. If `pair?` accepted any tuple
      # (size check → `true`), a pair-vs-3-tuple position would `{mk, mv} = <3-tuple>` and raise
      # a MatchError. With the size check, it falls through to `{:diff, o}` cleanly. The candidate
      # diffs a node whose child is a 2-tuple in `original` but a non-`ast_node` 3-tuple in
      # `mutated`, so `diff` compares the two at the pair branch.
      pair = {leaf(81, :a), leaf(82, :b)}
      three = {1, 2, 3}

      cand = in_place(node(80, [pair]), node(80, [three]))
      tree = node(80, [pair], [cand])

      # Must not raise (the size check makes `pair?` reject the 3-tuple): the kill is "mutant
      # raises a MatchError on `{mk, mv} = <3-tuple>`, original returns the tree unchanged".
      assert match?({:f, _, _}, Overlap.resolve(tree))
    end

    test "a single-element block wrapping a non-scalar is recursed (`scalar_wrapper?` is scalar-only)" do
      # `scalar_wrapper?` admits a `{:__block__, _, [v]}` only when `v` is a scalar; the inner
      # value is then compared directly. If the guard were `true`, two single-element blocks
      # wrapping *non-scalar* (call) nodes would take the scalar branch and return the whole block
      # as the footprint (nid 90, covering) instead of recursing to the inner call. The sibling
      # candidate at nid 90 would then be wrongly dropped. Original recurses → inner change → the
      # block stays non-covering, sibling survives.
      call_a = {:g, [mutare_nid: 91], [leaf(92, 1)]}
      call_b = {:g, [mutare_nid: 91], [leaf(92, 2)]}
      block_a = {:__block__, [mutare_nid: 90], [call_a]}
      block_b = {:__block__, [mutare_nid: 90], [call_b]}

      cand = in_place(node(95, [block_a]), node(95, [block_b]))

      # Host the sibling on the block node (nid 90); it is whole-host (non-covering) so survives
      # iff the block is NOT a covering footprint — i.e. iff `diff` recursed past the wrapper.
      block_host = {:__block__, [mutare_nid: 90, mutare: [in_place(block_a, block_b)]], [call_a]}
      tree = node(95, [block_host], [cand])

      survivors = surviving(Overlap.resolve(tree))
      assert {90, 90} in survivors
    end
  end
end
