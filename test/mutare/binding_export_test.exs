defmodule Mutare.BindingExportTest do
  @moduledoc """
  What a selector exports is decided by the scope the expression stands in
  (`Mutare.Transform.Bindings`), by the live candidates alone, and — for a closed-over pipe
  stage — only where argument 0's bindings are not read by the stage. Each case here is a
  source patch that once diverged from its metamutant, or a mutant that once failed the whole
  metamutant's compile.
  """
  use ExUnit.Case, async: false

  import Mutare.Test, only: [compile_metamutant: 3, with_active_mutant: 2]
  import Mutare.Test.SourcePatch, only: [assert_patches: 4]

  # `Enum.count(xs, p)` → `Enum.any?(xs, p)`: a second family on the same call, one that keeps
  # the binding argument the collection-arity mutant drops.
  defmodule KeepPredicate do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :keep_predicate

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, Enum, :count) do
        {:ok, :count, [values, predicate], rebuild} -> [rebuild.(:any?, [values, predicate])]
        _ -> []
      end
    end
  end

  # A macro that runs its second position before its first.
  defmodule ReverseOrder do
    defmacro sequence(read, write) do
      quote do
        unquote(write)
        unquote(read)
      end
    end
  end

  # `Enum.count(xs)` → `receiver().count(xs)`: argument 0 kept, a callee introduced.
  defmodule DynamicReceiver do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :dynamic_receiver

    @impl Mutare.Mutator
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, Enum, :count) do
        {:ok, :count, [values], _rebuild} ->
          [{{:., [], [{:receiver, [], []}, :count]}, [], [values]}]

        _ ->
          :skip
      end
    end
  end

  @count_calls [
    direct: "Enum.count([1], predicate = fn _ -> true end)",
    piped: "[1] |> Enum.count(predicate = fn _ -> true end)"
  ]

  describe "a name bound on entry is exported by every branch" do
    for {spelling, call} <- @count_calls do
      test "#{spelling}: a mutant that drops its rebinding leaves the incoming value" do
        source = count_fixture(unquote(call), "")

        # Original `{1, true}`; the `count/1` patch `{1, false}`, `predicate` still `:before`.
        assert [_ | _] =
                 assert_patches(source, [:collection_arity], [run: []], clean_functions: false)
      end
    end

    test "a head pattern's variable, inside a lifted function" do
      source = """
      defmodule Fixture do
        def run(predicate) when predicate != nil do
          result = Enum.count([1], predicate = fn _ -> true end)
          {result, is_function(predicate, 1)}
        end
      end
      """

      sites =
        assert_patches(source, [:collection_arity, :relational], [run: [:before]],
          clean_functions: false
        )

      assert Enum.any?(sites, &(&1.mutator == :collection_arity))
      assert Enum.any?(sites, &(&1.mutator == :relational))
    end

    test "a case clause's pattern variable" do
      source = """
      defmodule Fixture do
        def run(input) do
          case input do
            {:ok, predicate} ->
              result = Enum.count([1], predicate = fn _ -> true end)
              {result, is_function(predicate, 1)}

            :error ->
              :error
          end
        end
      end
      """

      sites =
        assert_patches(source, [:collection_arity], [run: [{:ok, :before}], run: [:error]],
          clean_functions: false
        )

      assert Enum.any?(sites, &(&1.mutator == :collection_arity))
    end

    test "a with clause's pattern variable" do
      source = """
      defmodule Fixture do
        def run(input) do
          with {:ok, predicate} <- input do
            result = Enum.count([1], predicate = fn _ -> true end)
            {result, is_function(predicate, 1)}
          end
        end
      end
      """

      sites =
        assert_patches(source, [:collection_arity], [run: [{:ok, :before}], run: [:error]],
          clean_functions: false
        )

      assert Enum.any?(sites, &(&1.mutator == :collection_arity))
    end

    for {spelling, call} <- [direct: "div(marker = 8, 2)", piped: "(marker = 8) |> div(2)"] do
      test "#{spelling}: under a conservative :lazy_expression route as under :expression" do
        source = """
        defmodule Fixture do
          def run do
            marker = :before
            result = #{unquote(call)}
            {result, marker}
          end
        end
        """

        # `:lazy_expression` only switches eager delivery off; `marker` is bound before the
        # call, so both `div/2` and its `rem/2` mutant leave `marker == 8` outside.
        assert [_ | _] =
                 assert_patches(source, [:arithmetic], [run: []],
                   clean_functions: false,
                   call_routes: [{Kernel, :div, 2, [:lazy_expression, :expression]}]
                 )
      end
    end
  end

  describe "a name bound fresh" do
    test "read later: a mutant that drops it is withheld, and the metamutant still compiles" do
      source = count_fixture("Enum.count([1], predicate = fn _ -> true end)", "")
      source = String.replace(source, "predicate = :before\n", "")

      # Patched into the source, `Enum.count([1])` leaves `is_function(predicate, 1)` reading an
      # unbound name; delivered, its branch could export nothing for it. Before the withholding
      # the whole metamutant failed to compile at that read, attributable to no mutant.
      assert [] = assert_patches(source, [:collection_arity], [run: []], clean_functions: false)
    end

    test "read by nothing: the mutant is delivered, its binding simply unexported" do
      source = """
      defmodule Fixture do
        def run, do: Enum.count([1], predicate = fn _ -> true end)
      end
      """

      assert [_] = assert_patches(source, [:collection_arity], [run: []], clean_functions: false)
    end

    test "rebound later before any read: withheld all the same (a read is over-approximated)" do
      source = """
      defmodule Fixture do
        def run do
          result = Enum.count([1], predicate = fn _ -> true end)
          predicate = :after
          {result, predicate}
        end
      end
      """

      assert [] = assert_patches(source, [:collection_arity], [run: []], clean_functions: false)
    end
  end

  describe "delivery is planned from the live candidates" do
    for {spelling, call} <- @count_calls do
      test "#{spelling}: an ignored binding-dropping candidate cannot trap the live one's binding" do
        source = count_fixture(unquote(call), "# mutare:ignore[collection_arity]")

        {[module], sites} =
          compile_metamutant(source, [KeepPredicate, :collection_arity], clean_functions: false)

        kept = Enum.find(sites, &(&1.mutator == :keep_predicate))
        assert kept, "expected the live any?/2 mutation"

        assert with_active_mutant(0, fn -> module.run() end) == {1, true}
        assert with_active_mutant(kept.id, fn -> module.run() end) == {true, true}
      end
    end

    for withhold <- [:skip_ids, :emit_ids] do
      test "a candidate withheld by #{withhold} cannot trap the live one's binding" do
        source = count_fixture("Enum.count([1], predicate = fn _ -> true end)", "")
        mutators = [KeepPredicate, :collection_arity]

        {_modules, sites} = compile_metamutant(source, mutators, clean_functions: false)
        dropping = Enum.find(sites, &(&1.mutator == :collection_arity))
        kept = Enum.find(sites, &(&1.mutator == :keep_predicate))

        withheld =
          case unquote(withhold) do
            :skip_ids -> [skip_ids: MapSet.new([dropping.id])]
            :emit_ids -> [emit_ids: MapSet.new([kept.id])]
          end

        {[module], _sites} =
          compile_metamutant(source, mutators, [clean_functions: false] ++ withheld)

        assert with_active_mutant(0, fn -> module.run() end) == {1, true}
        assert with_active_mutant(kept.id, fn -> module.run() end) == {true, true}
      end
    end
  end

  describe "a closed-over pipe stage" do
    for {spelling, expression} <- [
          direct: "Enum.count(input())",
          piped: "input() |> Enum.count()"
        ] do
      test "#{spelling}: a replacement introducing a receiver runs it before the operand" do
        source = """
        defmodule Fixture do
          defp input do
            record(:input)
            [1]
          end

          defp receiver do
            record(:receiver)
            Enum
          end

          defp record(event), do: Process.put(:events, [event | Process.get(:events, [])])

          def run do
            Process.put(:events, [])
            result = #{unquote(expression)}
            {result, :lists.reverse(Process.get(:events))}
          end
        end
        """

        # The original callee is inert, and the replacement keeps argument 0 — but its own
        # callee runs, and before the argument. Hoisting the operand would reverse the two.
        assert [_] =
                 assert_patches(source, [DynamicReceiver], [run: []], clean_functions: false)
      end
    end

    # Elixir itself rejects `(m = 1) |> div(m)` with no `m` bound before: only a rebinding
    # can be read by the stage, so these are the shapes that exist.
    test "reading what argument 0 rebinds keeps ordinary delivery" do
      source = """
      defmodule Fixture do
        def run do
          m = 10
          result = (m = 1) |> div(m)
          {result, m}
        end
      end
      """

      # The closure is created before its argument rebinds `m`: inside it `m` would be the
      # value captured at creation. Once the metamutant failed to compile at that read; now
      # such a stage is delivered branch-locally, like a direct call.
      assert [_ | _] = assert_patches(source, [:arithmetic], [run: []], clean_functions: false)
    end

    test "rebinding what argument 0 rebinds keeps ordinary delivery too" do
      source = """
      defmodule Fixture do
        def run do
          m = 10
          result = (m = 1) |> div(m = 5)
          {result, m}
        end
      end
      """

      assert [_ | _] = assert_patches(source, [:arithmetic], [run: []], clean_functions: false)
    end
  end

  describe "siblings of an expression" do
    # Elixir resets reads between the siblings of a call, a tuple, a list, an operator or a
    # map (`foo(x = 1, x)` does not compile) and lets their writes out only after the whole
    # expression, the last one winning. A position may not export a name an earlier sibling
    # writes as "incoming": that write would override the sibling's. So such a name is a
    # conflict there, and a mutant dropping it is withheld — its delivery would need a
    # selector around the enclosing expression. Every shape below asserts that the baseline
    # and whatever is delivered match the source; the conflicting ones deliver nothing.
    @sibling_shapes [
      call: "pair(p = :sibling, Enum.count([1], p = fn _ -> true end))",
      list: "[p = :sibling, Enum.count([1], p = fn _ -> true end)]",
      tuple: "{p = :sibling, Enum.count([1], p = fn _ -> true end)}",
      anonymous_callee: "(p = &Function.identity/1).(Enum.count([1], p = fn _ -> true end))",
      dynamic_receiver: "(p = Kernel).abs(Enum.count([1], p = fn _ -> true end))"
    ]

    for {shape, expression} <- @sibling_shapes do
      test "#{shape}: an earlier sibling's rebinding is not this position's incoming value" do
        source = """
        defmodule Fixture do
          defp pair(left, right), do: {left, right}

          def run do
            p = :incoming
            result = #{unquote(expression)}
            {result, p == :sibling}
          end
        end
        """

        assert [] = assert_patches(source, [:collection_arity], [run: []], clean_functions: false)
      end

      test "#{shape}: an earlier sibling's fresh binding is not readable in this position" do
        source = """
        defmodule Fixture do
          defp pair(left, right), do: {left, right}

          def run do
            result = #{unquote(expression)}
            {result, p == :sibling}
          end
        end
        """

        assert [] = assert_patches(source, [:collection_arity], [run: []], clean_functions: false)
      end
    end

    test "a keyed route's values are siblings, each other's writes read per treatment" do
      source = """
      defmodule Fixture do
        defp box(opts), do: opts

        def run do
          p = :incoming
          values = box(first: p = :sibling, second: Enum.count([1], p = fn _ -> true end))
          {values, p == :sibling}
        end
      end
      """

      assert [] =
               assert_patches(source, [:collection_arity], [run: []],
                 clean_functions: false,
                 call_routes: [{:*, :box, 1, [[:raw, first: :expression, second: :expression]]}]
               )
    end

    test "a compound route's writes reach its sibling positions" do
      source = """
      defmodule Fixture do
        defp pair(left, right), do: {left, right}

        def run do
          p = :incoming
          values = pair([item: p = :sibling], Enum.count([1], p = fn _ -> true end))
          {values, p == :sibling}
        end
      end
      """

      assert [] =
               assert_patches(source, [:collection_arity], [run: []],
                 clean_functions: false,
                 call_routes: [{:*, :pair, 2, [[:raw, item: :expression], :expression]}]
               )
    end

    test "a conflict on a write core cannot vouch for withholds the node, not the baseline" do
      source = """
      defmodule Fixture do
        defp pair(left, right), do: {left, right}

        def run do
          p = :incoming
          value = pair(p = :sibling, div(p = 8, 2))
          {value, p}
        end
      end
      """

      # `p = 8` sits in a `:lazy_expression` position: whether that write escapes is the
      # callee's. Exported, it may be the stale `:incoming`; trapped, the baseline loses the
      # `8` the source leaves. Neither is faithful, so `div` gets no selector at all.
      assert [] =
               assert_patches(source, [:arithmetic], [run: []],
                 clean_functions: false,
                 call_routes: [{Kernel, :div, 2, [:lazy_expression, :expression]}]
               )
    end

    for {shape, expression} <- [
          call: "pair(div(p = 8, 2), Enum.count([1], p = fn _ -> true end))",
          list: "[div(p = 8, 2), Enum.count([1], p = fn _ -> true end)]"
        ] do
      test "#{shape}: a sibling's write in a lazy position is a possible write, so a conflict" do
        source = """
        defmodule Fixture do
          defp pair(left, right), do: {left, right}

          def run do
            p = :incoming
            values = #{unquote(expression)}
            {values, p == 8}
          end
        end
        """

        # `div`'s first position is `:lazy_expression`: its `p = 8` is no guaranteed binding,
        # but it may run, and the source's patch leaves it as the outgoing `p`. The count
        # selector may not export `:incoming` over it.
        assert [] =
                 assert_patches(source, [:collection_arity], [run: []],
                   clean_functions: false,
                   call_routes: [{Kernel, :div, 2, [:lazy_expression, :expression]}]
                 )
      end
    end

    test "a routed macro's positions read each other whatever their written order" do
      source = """
      defmodule Fixture do
        require Mutare.BindingExportTest.ReverseOrder

        def run do
          Mutare.BindingExportTest.ReverseOrder.sequence(
            is_function(p, 1),
            Enum.count([1], p = fn _ -> true end)
          )
        end
      end
      """

      # The macro runs its second position first: the count's `p` is read by the first. The
      # dropping mutant has no compiling patch, and `later` for a routed position is every
      # other position's references, so it is withheld.
      assert [] =
               assert_patches(source, [:collection_arity], [run: []],
                 clean_functions: false,
                 call_routes: [
                   {ReverseOrder, :sequence, 2, [:lazy_expression, :lazy_expression]}
                 ]
               )
    end

    test "a parenthesized block sequences its statements wherever it stands" do
      source = """
      defmodule Fixture do
        def run do
          value = (
            p = :before
            Enum.count([1], p = fn _ -> true end)
          )

          {value, is_function(p, 1)}
        end
      end
      """

      assert [%{mutator: :collection_arity}] =
               assert_patches(source, [:collection_arity], [run: []], clean_functions: false)
    end
  end

  describe "a binding a route declares" do
    # `destructure/2`'s first position is routed `:binding_pattern`: it binds `x` without a
    # `=` in sight, and `x`, bound on entry, is exported like any rebinding.
    for {label, tail} <- [{"beside a match", "(y = 1)"}, {"alone", "1"}] do
      test "counts as a rebinding of a name bound on entry (#{label})" do
        source = """
        defmodule Fixture do
          def run(x) do
            result = length(destructure([x], [8])) + #{unquote(tail)}
            {result, x}
          end
        end
        """

        assert [_ | _] =
                 assert_patches(source, [:arithmetic], [run: [100]], clean_functions: false)
      end
    end
  end

  describe "an unresolved call is ordinary, whatever its keywords are named" do
    for {label, call} <- [
          {"only do", "value(do: n = 8)"},
          {"do first", "value(do: n = 8, other: 0)"},
          {"do last", "value(other: 0, do: n = 8)"}
        ] do
      test "a local function taking options exports its `do:` binding (#{label})" do
        source = """
        defmodule Fixture do
          defp value(opts), do: Keyword.fetch!(opts, :do)

          def run do
            result = div(#{unquote(call)}, 2)
            {result, n}
          end
        end
        """

        assert [_ | _] =
                 assert_patches(source, [:arithmetic], [run: []], clean_functions: false)
      end
    end
  end

  defp count_fixture(call, directive) do
    """
    defmodule Fixture do
      def run do
        predicate = :before
        #{directive}
        result = #{call}
        {result, is_function(predicate, 1)}
      end
    end
    """
  end
end
