defmodule Mutare.ResolveTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.Resolve

  # The per-node identity token `meta[:mutare_nid]` that `Mutare.Transform.Overlap`
  # prunes redundant leaf mutants on. These pin its contract *directly* — total
  # coverage, injectivity, and the load-bearing "no metadata → no nid" fact — rather
  # than via a downstream mutator symptom. The whole correctness argument for Overlap
  # (a false prune is unrepresentable) rests on these properties, so they earn an
  # explicit, mechanism-level guard.
  describe "node id stamping (mutare_nid)" do
    defp annotate(source), do: source |> Sourceror.parse_string!() |> Resolve.annotate()

    # Every `{form, meta, args}` node with list metadata, in DFS order.
    defp meta_nodes(ast) do
      {_ast, nodes} =
        Macro.prewalk(ast, [], fn
          {_f, meta, _a} = node, acc when is_list(meta) -> {node, [node | acc]}
          node, acc -> {node, acc}
        end)

      Enum.reverse(nodes)
    end

    test "stamps a unique nid on every metadata-bearing node (total + injective)" do
      # Two structurally identical `DateTime.truncate(a, :second)` calls make injectivity
      # non-trivial: range-equality could not tell them (or their `:second` leaves) apart,
      # node identity must.
      ast =
        annotate("""
        defmodule M do
          def f(a), do: DateTime.truncate(a, :second)
          def g(a), do: DateTime.truncate(a, :second)
        end
        """)

      nids = ast |> meta_nodes() |> Enum.map(&Resolve.nid/1)

      # Total: no metadata-bearing node is left unstamped.
      assert Enum.all?(nids, &is_integer/1)
      # Injective: every node — including the duplicated calls and their `:second` leaves —
      # gets a distinct id.
      assert nids == Enum.uniq(nids)
    end

    test "a bare atom and a list carry no nid — why operator/arity footprints never cover" do
      # An operator swap changes a bare form atom (`:-`); an arity drop / operand swap changes
      # the argument *list*. Neither shape carries metadata, so neither can be stamped — which
      # is exactly why Overlap treats those footprints as non-covering, with no special case.
      assert Resolve.nid(:-) == nil
      assert Resolve.nid([1, 2]) == nil

      # The operator *node* (`{:-, meta, [a, b]}`) — which actually hosts candidates — does
      # carry one, so a leaf swap on a genuine descendant can still be covered.
      {:-, _meta, [_a, _b]} = node = annotate("a - b")
      assert is_integer(Resolve.nid(node))
    end

    test "nids never leak into the rendered metamutant (stripped before render)" do
      # `:mutare_nid` is internal bookkeeping; like the other `mutare_*` meta keys it must be
      # stripped before Sourceror renders the build artifact.
      %{metamutant: metamutant} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(a), do: DateTime.truncate(a, :second)
          end
          """,
          mutators: [Mutare.Mutators.ModeSwap, Mutare.Mutators.AtomLiteral]
        )

      refute metamutant =~ "mutare_nid"
    end
  end
end
