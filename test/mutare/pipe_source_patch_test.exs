defmodule Mutare.PipeSourcePatchTest do
  # Every site a pipe produces, checked against the patch it promises (`Mutare.Test.SourcePatch`):
  # routed stages rewritten into direct calls and reported at the stage or over the whole pipe,
  # unrouted stages under the closure, displaced pipes, and the spellings `direct/1` special-cases.
  use ExUnit.Case, async: false

  import Mutare.Test.SourcePatch

  alias Mutare.Test.{LazyDSL, LazyStageMutator, PipedCallProbe, PipeSyntaxMutator}

  test "a routed stage reported at the stage, in a multi-line chain with a function tail" do
    source = """
    defmodule Fixture do
      import Mutare.Test.PipeSyntaxDSL

      def run(n) do
        n
        |> plus(1)
        |> plus(10)
        |> Integer.to_string()
      end
    end
    """

    sites = assert_patches(source, [PipeSyntaxMutator, :integer, :return_value], run: [5])

    assert Enum.map(
             Enum.filter(sites, &(&1.mutator == :pipe_syntax)),
             &{&1.line, &1.original_code}
           ) ==
             [{6, "plus(1)"}, {7, "plus(10)"}]
  end

  test "a routed stage in tail position, where return-value mutants cover the whole pipe" do
    source = """
    defmodule Fixture do
      import Mutare.Test.PipeSyntaxDSL

      def run(n) do
        (x in n)
        |> raw(x + 1)
      end
    end
    """

    sites = assert_patches(source, [PipeSyntaxMutator, :return_value, :integer], run: [5])
    assert Enum.any?(sites, &(&1.mutator == :return_value and &1.line == 5))
  end

  test "a mutant that rewrites the piped operand is patched over the whole pipe" do
    source = """
    defmodule Fixture do
      import Mutare.Test.PipedCallDSL

      def run(x, n) do
        found = (p in n) |> stage(x > 1)
        found
      end
    end
    """

    [site] = assert_patches(source, [PipedCallProbe], run: [2, [1, 2]], run: [0, [1, 2]])
    assert site.original_code == "(p in n) |> stage(x > 1)"
  end

  test "upstream mutants of a routed stage, under each position-0 treatment" do
    for {stage, left} <- [keyword: "[value: 4 + 1]", keyed: "[value: 4 + 1]", interpolated: "5"] do
      source = """
      defmodule Fixture do
        import Mutare.Test.PipeSyntaxDSL
        def run, do: #{left} |> #{stage}(5)
      end
      """

      assert [_ | _] = assert_patches(source, [PipeSyntaxMutator, :integer, :arithmetic], run: [])
    end
  end

  test "stages written without parentheses" do
    source = """
    defmodule Fixture do
      import Mutare.Test.LazyDSL

      def run(n) do
        a = n |> Integer.to_string
        b = n |> Kernel.to_string
        # Inside an argument list, a call rendered without parentheses would swallow the
        # arguments after it: `pair(Integer.to_string n, 1)`.
        {a, b, (n + 1) |> lazy(n > 0), pair(n |> Integer.to_string, 1)}
      end

      defp pair(a, b), do: {a, b}
    end
    """

    routes = [
      {Integer, :to_string, 1, [:expression]},
      {Kernel, :to_string, 1, [:lazy_expression]},
      {LazyDSL, :lazy, 2, [:lazy_expression, :expression]}
    ]

    sites =
      assert_patches(source, [:arithmetic, :integer, LazyStageMutator], [run: [4]],
        call_routes: routes
      )

    assert Enum.any?(sites, &(&1.mutator == :lazy_stage))
  end

  test "an unrouted chain under the hoisting closure" do
    source = """
    defmodule Fixture do
      def run(xs) do
        xs
        |> Enum.reject(&(&1 > 2))
        |> Enum.map(&(&1 + 1))
        |> Enum.sum()
      end
    end
    """

    assert [_ | _] =
             assert_patches(source, [:collection, :arithmetic, :relational, :integer],
               run: [[1, 2, 3]]
             )
  end

  test "a displaced pipe" do
    source = """
    defmodule Fixture do
      import Kernel, except: [|>: 2]
      import Mutare.Test.BindPipe

      def run(result), do: result |> Enum.reject(&(&1 > 1 + 1))
    end
    """

    assert [_ | _] =
             assert_patches(
               source,
               [:collection, :integer, :relational, :arithmetic],
               [run: [{:ok, [1, 2, 3]}], run: [:error]],
               call_routes: [{Mutare.Test.BindPipe, :|>, 2, [:expression, :interior]}]
             )
  end

  describe "a rewritten stage that binds its piped value" do
    defmodule BumpZero do
      # `bump(a, k)` → `bump(a, 0)`: a whole-call mutant, by name, that keeps argument 0.
      @behaviour Mutare.Mutator
      def name, do: :bump_zero

      def mutate({:bump, meta, [source, _k]}),
        do: [{:bump, meta, [source, Mutare.AST.literal(0)]}]

      def mutate(_node), do: :skip
    end

    defmodule PlusToLazy do
      # Renames `plus` to its sibling through `rebuild`, which requalifies a selectively imported
      # call — the mutant's head changes shape while its argument 0 stays put.
      @behaviour Mutare.Mutator
      alias Mutare.CallRouting.Call

      def name, do: :plus_to_lazy

      def mutate(node, _context) do
        case Mutare.Calls.resolved_routed_call(node) do
          %Call{name: :plus, arguments: args, rebuild: rebuild} -> [rebuild.(:lazy_plus, args)]
          _other -> :skip
        end
      end
    end

    defmodule FilterAll do
      # A whole-call mutant on `HostDSL.filter/2`, beside the hosted mutants of its condition.
      @behaviour Mutare.Mutator
      def name, do: :filter_all

      def mutate({:filter, meta, [query, _condition]}),
        do: [{:filter, meta, [query, Mutare.AST.literal(true)]}]

      def mutate(_node), do: :skip
    end

    defmodule BumpSource do
      # `bump(a, k)` → `bump(a + 100, k)`: a whole-call mutant that rewrites argument 0.
      @behaviour Mutare.Mutator
      def name, do: :bump_source

      def mutate({:bump, meta, [source, k]}),
        do: [{:bump, meta, [{:+, [], [source, Mutare.AST.literal(100)]}, k]}]

      def mutate(_node), do: :skip
    end

    test "keeps a mutant that rewrites the piped value out of the binding" do
      # Bound, the mutant's own argument 0 would be replaced by the variable and the mutation
      # lost: the patch check sees a mutant that behaves like the original. It is delivered in
      # a selector around the closure, which binds the stage's other mutants as usual.
      source = """
      defmodule Fixture do
        def run(n), do: n |> bump(1) |> bump(2)
        defp bump(a, k), do: a + k
      end
      """

      opts = [call_routes: [{:*, :bump, 2, [:expression, :expression]}]]
      sites = assert_patches(source, [BumpSource, BumpZero], [run: [5]], opts)

      assert [%{original_code: "n |> bump(1)"}, %{original_code: "n |> bump(1) |> bump(2)"}] =
               Enum.filter(sites, &(&1.mutator == :bump_source))

      emitted = Mutare.Test.metamutant_source(source, [BumpSource, BumpZero], opts)
      assert emitted =~ "(n + 100) |> bump(1)"
      assert emitted =~ "mutare_piped |> bump(0)"
    end

    test "with position 0 routed :interior" do
      source = """
      defmodule Fixture do
        def run(n), do: (n + 1) |> bump(1) |> bump(2)
        defp bump(a, k), do: a + k
      end
      """

      opts = [call_routes: [{:*, :bump, 2, [:interior, :expression]}]]
      sites = assert_patches(source, [BumpZero, :integer, :arithmetic], [run: [5]], opts)

      # `:interior` withholds an argument's *own* node, and the outer stage's argument 0 is the
      # inner stage: so only the outer `bump` is mutated whole, and only it binds. The inner
      # stage's own argument 0, `n + 1`, is withheld the same way; the literals inside both mutate.
      assert [%{original_code: "bump(2)"}] = Enum.filter(sites, &(&1.mutator == :bump_zero))
      refute Enum.any?(sites, &(&1.original_code == "n + 1"))

      # `1` mutates in both places it appears. `2` does not: `BumpZero` substitutes exactly that
      # node, which makes it the rewrite's to own (`Mutare.Transform.Overlap`) — in a direct call
      # just the same.
      assert sites
             |> Enum.filter(&(&1.mutator == :integer))
             |> Enum.map(& &1.original_code)
             |> Enum.uniq() == ["1"]

      emitted = Mutare.Test.metamutant_source(source, [BumpZero, :integer, :arithmetic], opts)
      assert length(Regex.scan(~r/fn mutare_piped ->/, emitted)) == 1
    end

    test "when the mutant's head is requalified by rebuild" do
      source = """
      defmodule Fixture do
        import Mutare.Test.PipeSyntaxDSL, only: [plus: 2, lazy_plus: 2]
        def run(n), do: n |> plus(1) |> plus(-3)
      end
      """

      sites =
        assert_patches(source, [PlusToLazy], [run: [5]], extensions: [Mutare.Test.PipeSyntaxDSL])

      assert [%{original_code: "plus(1)"}, %{original_code: "plus(-3)"}] = sites
      assert Enum.all?(sites, &(&1.mutated_code =~ "PipeSyntaxDSL.lazy_plus("))
    end

    test "beside hosted mutants woven into another argument" do
      source = """
      defmodule Fixture do
        import Mutare.Test.HostDSL
        def run(xs, x), do: xs |> Enum.reverse() |> filter(x > 1)
      end
      """

      mutators = [Mutare.Test.HostMutator, FilterAll]

      sites =
        assert_patches(source, mutators, run: [[1, 2], 2], run: [[1, 2], 1], run: [[1, 2], 0])

      assert Enum.any?(sites, &(&1.mutator == :host_filter))
      assert Enum.any?(sites, &(&1.mutator == :filter_all))

      emitted = Mutare.Test.metamutant_source(source, mutators)
      assert emitted =~ "fn mutare_piped ->"
    end
  end

  test "a pinned selector on the left of a skipped stage keeps its precedence" do
    # `--skip-call` on a macro displaces its route, and the displaced route still answers for the
    # piped operand: here `:interpolated`, so the literal's mutants are delivered `^`-pinned on
    # the left of a stage that stays a pipe. Rendered naively, `^case … end |> stage()` reparses
    # as `^(case … end |> stage())`.
    source = """
    defmodule Fixture do
      import Mutare.Test.PipeSyntaxDSL
      def run, do: 5 |> interpolated(5)
    end
    """

    sites =
      assert_patches(source, [PipeSyntaxMutator, :integer], [run: []],
        call_routes: [{Mutare.Test.PipeSyntaxDSL, :interpolated, 2, :skip}]
      )

    assert Enum.map(sites, & &1.original_code) |> Enum.uniq() == ["5"]
    assert Enum.all?(sites, &(&1.column == 16))
  end
end
