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

  # `destructure([x, y], v)` → `x = 9`: a whole-call mutation that binds one pattern name and
  # drops the other, re-homed as a `MacroPattern` branch of the tuple-export selector.
  defmodule ReplaceWithAssignment do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :replace_with_assignment

    @impl Mutare.Mutator
    def mutate({:destructure, _meta, [_pattern, _value]}), do: [{:=, [], [{:x, [], nil}, 9]}]
    def mutate(_node), do: :skip
  end

  # `Mutare.Test.QueryDSL.unpack/2` routed through a **classifier** — the same positions
  # `UnpackMutator` declares statically, obtained per call. Under a skipped wrapper the
  # classifier is never invoked, so the call's binding effect is unknown there.
  defmodule ClassifiedUnpack do
    @behaviour Mutare.Mutator
    @behaviour Mutare.CallRouting

    @impl Mutare.Mutator
    def name, do: :classified_unpack

    @impl Mutare.Mutator
    def mutate(_node), do: :skip

    @impl Mutare.CallRouting
    def call_routes, do: [{Mutare.Test.QueryDSL, :unpack, 2, :routing}]

    @impl Mutare.CallRouting
    def route_arguments(call),
      do: Mutare.CallRouting.ArgumentRoutes.new(call, [:binding_pattern, :expression])
  end

  # A macro that runs its argument, routed `:lazy_expression` — the least convenient valid
  # reading of the word: core may not assume the argument runs, and here it does.
  defmodule Eager do
    defmacro run(value), do: quote(do: unquote(value))
  end

  # A binding macro spelled `if/2`, imported over Kernel's: a displaced Kernel name whose
  # unstamped occurrence under a skipped wrapper must still read as this call, not a conditional.
  defmodule DisplacedIf do
    import Kernel, except: [if: 2]

    # credo:disable-for-next-line Credo.Check.Readability.ParenthesesInCondition
    defmacro if(pattern, value) do
      quote do: unquote(pattern) = unquote(value)
    end
  end

  defmodule RouteDisplacedIf do
    @behaviour Mutare.Mutator
    @behaviour Mutare.CallRouting

    @impl Mutare.Mutator
    def name, do: :route_displaced_if

    @impl Mutare.Mutator
    def mutate(_node), do: :skip

    @impl Mutare.CallRouting
    def call_routes,
      do: [{Mutare.BindingExportTest.DisplacedIf, :if, 2, [:binding_pattern, :expression]}]
  end

  @lazy_div [{Kernel, :div, 2, [:lazy_expression, :expression]}]

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

    # A binding a route declares (`destructure/2`'s pattern) is a possible write like a match,
    # at any depth and under any treatment — here beneath a `:lazy_expression` position,
    # where it is not a *guaranteed* binding, so only `matched_names/1` can see it.
    @nested_declared "div(hd(destructure([p], [8])), 2)"

    for outer <- [:ordinary, :routed] do
      test "#{outer} siblings: an earlier sibling's nested declared write is a conflict" do
        source = """
        defmodule Fixture do
          defp pair(left, right), do: {left, right}

          def run do
            p = :incoming
            values = pair(#{@nested_declared}, Enum.count([1], p = fn _ -> true end))
            {values, p == 8}
          end
        end
        """

        routes =
          case unquote(outer) do
            :ordinary -> @lazy_div
            :routed -> @lazy_div ++ [{:*, :pair, 2, [:expression, :expression]}]
          end

        assert [] =
                 assert_patches(source, [:collection_arity], [run: []],
                   clean_functions: false,
                   call_routes: routes
                 )
      end
    end

    test "a nested declared write core cannot vouch for withholds the node, not the baseline" do
      source = """
      defmodule Fixture do
        defp pair(left, right), do: {left, right}

        def run do
          p = :incoming
          result = pair(p = :sibling, #{@nested_declared})
          {result, p}
        end
      end
      """

      assert [] =
               assert_patches(source, [:arithmetic], [run: []],
                 clean_functions: false,
                 call_routes: @lazy_div
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
    for {spelling, expression} <- [
          direct: "div(hd(destructure([p], [8])), 2)",
          piped: "hd(destructure([p], [8])) |> div(2)"
        ] do
      test "#{spelling}: nested under a lazy position, still a rebinding of a name bound on entry" do
        source = """
        defmodule Fixture do
          def run do
            p = :incoming
            result = #{unquote(expression)}
            {result, p}
          end
        end
        """

        # No `=` in sight and no guaranteed escape through the lazy position: `p` is exported
        # because a route declares the write, and it is bound on entry with no conflict.
        assert [_ | _] =
                 assert_patches(source, [:arithmetic], [run: []],
                   clean_functions: false,
                   call_routes: @lazy_div
                 )
      end

      test "#{spelling}: the eager control" do
        source = """
        defmodule Fixture do
          def run do
            p = :incoming
            result = #{unquote(expression)}
            {result, p}
          end
        end
        """

        assert [_ | _] = assert_patches(source, [:arithmetic], [run: []], clean_functions: false)
      end
    end

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

  describe "a structural pattern selector exports what its expression binds" do
    # The tuple-export delivery runs a `=`'s RHS, or a binding macro's whole call, inside a
    # selector branch: what that expression binds beyond the pattern is trapped there unless
    # the export carries it out. Each case below once diverged from its source patch at the
    # *baseline*, or failed the whole metamutant's compile.
    for {label, prelude} <- [{"rebinding", "values = :before"}, {"fresh", ""}] do
      test "a match RHS argument's #{label} escapes with the pattern" do
        source = """
        defmodule Fixture do
          def run do
            #{unquote(prelude)}
            {low, high} = Enum.min_max(values = [1, 2])
            {low, high, values}
          end
        end
        """

        # Original `{1, 2, [1, 2]}`; the swap `{2, 1, [1, 2]}` — never `:before`, never unbound.
        sites = assert_patches(source, [:pattern_swap], [run: []], clean_functions: false)
        assert Enum.any?(sites, &(&1.mutator == :pattern_swap))
      end

      test "a binding macro's value argument's #{label} escapes with the pattern" do
        source = """
        defmodule Fixture do
          def run do
            #{unquote(prelude)}
            destructure([low, high], values = [1, 2])
            {low, high, values}
          end
        end
        """

        sites = assert_patches(source, [:pattern_swap], [run: []], clean_functions: false)
        assert Enum.any?(sites, &(&1.mutator == :pattern_swap))
      end
    end

    test "a declared binding nested in a match RHS escapes with the pattern" do
      source = """
      defmodule Fixture do
        def run do
          x = :before
          y = :before
          {a, b} = List.to_tuple(destructure([x, y], [1, 2]))
          {a, b, x, y}
        end
      end
      """

      # Original `{1, 2, 1, 2}`: the inner `destructure/2` is a value here, not a statement,
      # so only the outer pattern is offered — and its export must still carry `x` and `y`.
      sites = assert_patches(source, [:pattern_swap], [run: []], clean_functions: false)
      assert Enum.any?(sites, &(&1.mutator == :pattern_swap))
    end

    test "a fresh RHS binding nothing reads stays trapped, unexported" do
      source = """
      defmodule Fixture do
        def run do
          {low, high} = Enum.min_max(values = [1, 2])
          {low, high}
        end
      end
      """

      %{metamutant: meta, sites: sites} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PatternSwap]
        )

      assert Enum.any?(sites, &(&1.mutator == :pattern_swap))
      assert meta =~ "{low, high} ="
      refute meta =~ "values} ="
    end

    test "a pin the RHS may rebind anywhere withholds the pattern's candidates" do
      # Elixir reads `^x` from before the whole match; the generated `case RHS do {^x, y} …`
      # would read it after the RHS rebound it, so `run(2)` would match where the source raises.
      # The chain-only check (`{^x, y} = {x, _} = e`) missed a rebinding inside an argument.
      source = """
      defmodule Fixture do
        def run(value) do
          x = 1
          {^x, y} = Function.identity({x = value, :ok})
          {x, y}
        end
      end
      """

      assert [] =
               assert_patches(source, [:pattern_swap], [run: [1], run: [2]],
                 clean_functions: false
               )
    end

    test "a re-homed whole-call mutant dropping a fresh binding read later is withheld" do
      # `Mutare.Test.UnpackMutator` replaces `unpack/2`'s value with a literal — dropping the
      # `v` the value bound. Read after, that patch would not compile; the pattern swap, which
      # keeps the value, is still delivered, and its export carries `v` out.
      source = unpack_fixture("", "{x - y, v}")

      sites =
        assert_patches(source, [:pattern_swap, Mutare.Test.UnpackMutator], [run: []],
          clean_functions: false
        )

      assert Enum.map(sites, & &1.mutator) == [:pattern_swap]
    end

    test "a re-homed whole-call mutant dropping a fresh binding nothing reads is delivered" do
      source = unpack_fixture("", "x - y")

      sites =
        assert_patches(source, [:pattern_swap, Mutare.Test.UnpackMutator], [run: []],
          clean_functions: false
        )

      assert Enum.sort(Enum.map(sites, & &1.mutator)) == [:pattern_swap, :unpack_call]
    end

    test "a re-homed whole-call mutant dropping a rebinding leaves the incoming value" do
      # The source patch `unpack([x, y], [9, 9])` leaves `v == :before`; so must the branch.
      source = unpack_fixture("v = :before", "{x - y, v}")

      sites =
        assert_patches(source, [:pattern_swap, Mutare.Test.UnpackMutator], [run: []],
          clean_functions: false
        )

      assert Enum.sort(Enum.map(sites, & &1.mutator)) == [:pattern_swap, :unpack_call]
    end
  end

  describe "a re-homed whole-call mutant must fill the fixed export tuple" do
    # `ReplaceWithAssignment` turns `destructure([x, y], v)` into `x = 9`: a valid source
    # mutation wherever nothing reads `y` after. The branch returns the selector's tuple
    # `{x, y}` all the same, so unless the scope supplies `y` the branch cannot fill it.
    test "a fresh pattern name nothing reads: withheld, not a manufactured compile error" do
      source = destructure_fixture("", "x")

      assert [] =
               assert_patches(source, [ReplaceWithAssignment], [run: []], clean_functions: false)
    end

    test "the same name bound on entry: delivered, the tuple names the incoming value" do
      source = destructure_fixture("y = :before", "x")

      assert [_] =
               assert_patches(source, [ReplaceWithAssignment], [run: []], clean_functions: false)
    end

    test "a fresh pattern name read after: withheld as any binding drop is" do
      source = destructure_fixture("", "{x, y}")

      assert [] =
               assert_patches(source, [ReplaceWithAssignment], [run: []], clean_functions: false)
    end
  end

  describe "a skipped call's arguments keep their binding facts" do
    # Skip withholds mutation and nested routing, not evaluation: `destructure/2` binds under a
    # skipped wrapper as anywhere. Resolve does not walk a skipped call's arguments, so the
    # nested call carries no route stamp; the binding readers resolve its static route through
    # the environment the skipped call retains instead.
    @skip_to_tuple [call_routes: [{List, :to_tuple, 1, :skip}], clean_functions: false]

    for {label, prelude} <- [{"rebinding", "left = :before\n    right = :before"}, {"fresh", ""}] do
      test "a declared #{label} under a skipped wrapper escapes a structural selector" do
        source = skipped_match_fixture(unquote(prelude))

        # Original `{1, 2, 1, 2}`; the swap `{2, 1, 1, 2}` — never `:before`, never unbound.
        sites = assert_patches(source, [:pattern_swap], [run: []], @skip_to_tuple)
        assert Enum.any?(sites, &(&1.mutator == :pattern_swap))
      end
    end

    test "a declared rebinding under a skipped wrapper escapes an ordinary selector" do
      source = """
      defmodule Fixture do
        def run do
          n = :before
          result = div(hd(destructure([n], [8])), 2)
          {result, n}
        end
      end
      """

      # Original `{4, 8}`; `div` → `rem` `{0, 8}`.
      sites =
        assert_patches(source, [:arithmetic], [run: []],
          call_routes: [{Kernel, :hd, 1, :skip}],
          clean_functions: false
        )

      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
    end

    test "a declared rebinding under a skipped wrapper reaches the pin check" do
      source = """
      defmodule Fixture do
        def run(value) do
          x = 1
          {^x, y} = List.to_tuple(destructure([x, spare], [value, :ok]))
          {x, y}
        end
      end
      """

      assert [] = assert_patches(source, [:pattern_swap], [run: [1], run: [2]], @skip_to_tuple)
    end

    test "a written pipe under a skipped wrapper is read as the call it denotes" do
      source = """
      defmodule Fixture do
        def run do
          left = :before
          {low, high} = List.to_tuple([left] |> destructure([1]) |> Kernel.++([2]))
          {low, high, left}
        end
      end
      """

      sites = assert_patches(source, [:pattern_swap], [run: []], @skip_to_tuple)
      assert Enum.any?(sites, &(&1.mutator == :pattern_swap))
    end

    # A classifier is never invoked in a region skip withheld it from. Its call is not
    # unrouted for that — the declaration is in the registry — so its effect is unknown, and
    # the selector that would trap what it binds is withheld rather than built on a guess.
    test "a classifier the skip withheld reads as unknown: the structural selector is withheld" do
      source = skipped_unpack_fixture("left = :before\n    right = :before")
      mutators = [:pattern_swap, ClassifiedUnpack]

      assert [] = assert_patches(source, mutators, [run: []], @skip_to_tuple)

      # The same classifier, invoked where nothing withholds it, routes as declared.
      sites = assert_patches(source, mutators, [run: []], clean_functions: false)
      assert Enum.any?(sites, &(&1.mutator == :pattern_swap))
    end

    test "a displaced Kernel name under a skipped wrapper is read by its route" do
      source = """
      defmodule Fixture do
        import Kernel, except: [if: 2]
        import Mutare.BindingExportTest.DisplacedIf, only: [if: 2]

        def run do
          {low, high} = List.to_tuple(if([left, right], [1, 2]))
          {low, high, left, right}
        end
      end
      """

      mutators = [:pattern_swap, RouteDisplacedIf]

      for opts <- [@skip_to_tuple, [clean_functions: false]] do
        sites = assert_patches(source, mutators, [run: []], opts)
        assert Enum.any?(sites, &(&1.mutator == :pattern_swap))
      end
    end
  end

  describe "the gate reads the source node, not its emitted children" do
    # Emission is bottom-up: by the time a parent's candidates are delivered, its children are
    # selectors. The inner `div` selector exports `x` through a tuple that also binds its
    # result temporary — a name no source replacement of `abs(...)` could keep. The gate reads
    # the node before its children are emitted, so the temporary is not a binding it demands.
    @default_source ~S"""
    defmodule Fixture do
      def run(value \\ abs(div(x = 8, 3))), do: value
      def other, do: div(9, 4)
    end
    """

    @parent_and_child [:arithmetic, :call_removal]

    test "a child selector's export temporary is not a binding the parent must keep" do
      sites =
        assert_patches(@default_source, @parent_and_child, [run: [], other: []],
          clean_functions: false
        )

      assert Enum.any?(sites, &(&1.mutator == :call_removal))
    end

    # A withheld artifact must not change which candidates exist: the ids poison recovery
    # skips and `--line` focuses on are claimed from the source alone.
    for withhold <- [:skip_ids, :emit_ids] do
      test "#{withhold} withholding the child leaves every id where the full build put it" do
        %{sites: all} = transform(@default_source, @parent_and_child)
        [inner | _] = Enum.filter(all, &(&1.mutator == :arithmetic))
        later = all |> Enum.filter(&(&1.mutator == :arithmetic)) |> List.last()

        withheld =
          case unquote(withhold) do
            :skip_ids -> [skip_ids: MapSet.new([inner.id])]
            :emit_ids -> [emit_ids: MapSet.new([later.id])]
          end

        %{sites: sites} = transform(@default_source, @parent_and_child, withheld)
        assert signatures(sites) == signatures(all)
      end
    end

    test "an ignored child leaves the count and render passes agreeing" do
      source =
        String.replace(@default_source, "  def run", "  # mutare:ignore[arithmetic]\n  def run")

      opts = [clean_functions: false, file: "lib/fixture.ex", mutators: @parent_and_child]

      %{sites: sites, next_id: next_id} =
        Mutare.Transform.transform_string_with_sites(source, opts)

      assert Mutare.Transform.count_string(source, opts) == length(sites)
      assert next_id == length(sites) + 1
    end
  end

  describe "an effect core cannot read, outside the node" do
    # `hd/1` skipped, `unpack/2` routed by the classifier the skip withholds: the first
    # sibling's binding effect is unknown. The node under test does not contain it — its
    # scope does — so the gate's own unknown check does not reach it.
    @unknown_write "hd(unpack([p], [8]))"
    @dropping_call "Enum.count([1], p = fn _ -> true end)"
    @skip_hd [{Kernel, :hd, 1, :skip}]

    @unknown_sibling_shapes [
      {:list, "[#{@unknown_write}, #{@dropping_call}]", "", []},
      {:tuple, "{#{@unknown_write}, #{@dropping_call}}", "", []},
      {:call, "pair(#{@unknown_write}, #{@dropping_call})", "defp pair(a, b), do: {a, b}", []},
      {:routed_call, "pair(#{@unknown_write}, #{@dropping_call})", "defp pair(a, b), do: {a, b}",
       [{:*, :pair, 2, [:expression, :expression]}]},
      {:keyed, "box(first: #{@unknown_write}, second: #{@dropping_call})",
       "defp box(opts), do: opts",
       [{:*, :box, 1, [[:raw, first: :expression, second: :expression]]}]}
    ]

    for {shape, expression, helper, routes} <- @unknown_sibling_shapes do
      test "#{shape}: an unknown earlier sibling's possible writes are this position's conflicts" do
        # Original `{_, false}`: the second sibling's write wins. Dropping the predicate
        # leaves the first sibling's `8`: `{_, true}`. An export of the incoming `:incoming`
        # over that write would read `false` again — a false survivor — so the dropping
        # mutant is withheld, as it is after a sibling whose write core can read.
        source = """
        defmodule Fixture do
          import Mutare.Test.QueryDSL
          #{unquote(helper)}

          def run do
            p = :incoming
            values = #{unquote(expression)}
            {values, p == 8}
          end
        end
        """

        assert [] =
                 assert_patches(source, [:collection_arity, ClassifiedUnpack], [run: []],
                   clean_functions: false,
                   call_routes: @skip_hd ++ unquote(Macro.escape(routes))
                 )
      end
    end

    @unknown_then_lazy """
    defmodule Fixture do
      import Mutare.Test.QueryDSL

      def run do
        hd(unpack([p], [8]))
        result = div(p = 6, 2)
        {result, p}
      end
    end
    """

    @lazy_div [{Kernel, :div, 2, [:lazy_expression, :expression]}]

    # Original `{3, 6}`, the `rem` patch `{0, 6}`: the first statement binds `p`, and nothing
    # can read that it does. Not bound, `p` would take the fresh rule at `div`; not escaping
    # there (the position is lazy), it would stay trapped, and the baseline would read `8`.
    test "an unknown earlier statement leaves its names uncertain: a lazy rebinding is withheld" do
      assert [] =
               assert_patches(@unknown_then_lazy, [:arithmetic, ClassifiedUnpack], [run: []],
                 clean_functions: false,
                 call_routes: @skip_hd ++ @lazy_div
               )
    end

    test "control: an eager rebinding after the same statement is delivered, exported as fresh" do
      sites =
        assert_patches(@unknown_then_lazy, [:arithmetic, ClassifiedUnpack], [run: []],
          clean_functions: false,
          call_routes: @skip_hd
        )

      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
    end

    test "control: a static declaration binds the name, and the lazy rebinding exports it" do
      sites =
        assert_patches(@unknown_then_lazy, [:arithmetic, Mutare.Test.UnpackMutator], [run: []],
          clean_functions: false,
          call_routes: @skip_hd ++ @lazy_div
        )

      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
    end

    # The same uncertainty without a classifier: a match in a lazy position is a possible
    # write of the statement, and the macro does run it, so the source's `p` is `8` before
    # `div` and `6` after it — `{3, 6}`, the `rem` patch `{0, 6}`.
    test "a possible write in a lazy position before the node is uncertain there, not fresh" do
      source = """
      defmodule Fixture do
        require Mutare.BindingExportTest.Eager, as: Eager

        def run do
          Eager.run(p = 8)
          result = div(p = 6, 2)
          {result, p}
        end
      end
      """

      assert [] =
               assert_patches(source, [:arithmetic], [run: []],
                 clean_functions: false,
                 call_routes: [{Eager, :run, 1, [:lazy_expression]}] ++ @lazy_div
               )
    end
  end

  defp transform(source, mutators, extra \\ []) do
    Mutare.Transform.transform_string_with_sites(
      source,
      [clean_functions: false, file: "lib/fixture.ex", mutators: mutators] ++ extra
    )
  end

  defp signatures(sites), do: Enum.map(sites, &Map.take(&1, [:id, :mutator, :range]))

  defp skipped_match_fixture(prelude) do
    """
    defmodule Fixture do
      def run do
        #{prelude}
        {low, high} = List.to_tuple(destructure([left, right], [1, 2]))
        {low, high, left, right}
      end
    end
    """
  end

  defp skipped_unpack_fixture(prelude) do
    """
    defmodule Fixture do
      import Mutare.Test.QueryDSL

      def run do
        #{prelude}
        {low, high} = List.to_tuple(unpack([left, right], [1, 2]))
        {low, high, left, right}
      end
    end
    """
  end

  defp destructure_fixture(prelude, result) do
    """
    defmodule Fixture do
      def run do
        #{prelude}
        destructure([x, y], [1, 2])
        #{result}
      end
    end
    """
  end

  defp unpack_fixture(prelude, result) do
    """
    defmodule Fixture do
      import Mutare.Test.QueryDSL

      def run do
        #{prelude}
        unpack([x, y], v = [5, 2])
        #{result}
      end
    end
    """
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
