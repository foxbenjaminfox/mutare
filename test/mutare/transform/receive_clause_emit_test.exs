defmodule Mutare.Transform.ReceiveClauseEmitTest do
  use ExUnit.Case, async: false
  import Mutare.Test.Metamutant

  alias Mutare.Coverage.Recorder
  alias Mutare.{Manifest, Selector, Transform}

  defmodule CoverageSink do
    def hit(ids) do
      send(Process.get(:receive_coverage_observer), {:covered, self(), ids})
      true
    end
  end

  defmodule WholeReceive do
    @behaviour Mutare.Mutator
    def name, do: :whole_receive
    def mutate({:receive, _, _}), do: [Mutare.AST.literal(:replaced)]
    def mutate(_), do: :skip
  end

  defmodule PoisonGuard do
    @behaviour Mutare.Mutator
    def name, do: :poison_receive_guard
    def mutate({:>, _, [x, _]}), do: [quote(do: Map.new(unquote(x)))]
    def mutate(_), do: :skip
  end

  defmodule StageSwap do
    @behaviour Mutare.Mutator
    def name, do: :stage_swap
    def mutate({:stage, _, []}), do: [quote(do: List.wrap())]
    def mutate(_), do: :skip
  end

  setup do
    previous = :persistent_term.get(Recorder.track_key(), false)
    Selector.put(Selector.baseline())
    :persistent_term.put(Recorder.track_key(), false)

    on_exit(fn ->
      Selector.put(Selector.baseline())
      :persistent_term.put(Recorder.track_key(), previous)
    end)

    :ok
  end

  test "one receive, C+M message clauses and one coverage payload as the clause count doubles" do
    sizes =
      for count <- [20, 40] do
        clauses = Enum.map_join(1..count, "\n", &"#{&1} -> :matched")

        {_, sites, metamutant} =
          compile_fixture(
            :Growth,
            "def take do\nreceive do\n#{clauses}\nafter\n0 -> :timeout\nend\nend"
          )

        assert [{messages, [_after_clause]}] = receives(metamutant)
        assert length(messages) == count + length(sites)
        assert coverage_payloads(metamutant) == [Enum.map(sites, & &1.id)]
        assert Enum.all?(sites, &(&1.kind == :in_place))
        byte_size(metamutant)
      end

    [small, large] = sizes
    assert large < small * 2.2
  end

  test "every mutant matches its source patch in result and remaining mailbox order" do
    body = """
    def take do
      receive do
        :early -> :early
        1 -> :one
        2 -> :two
        {a, a} -> {:same, a}
        {a, b} -> {:pair, a, b}
        n when n > 5 when is_binary(n) -> {:guard, n}
        x when is_map(x) -> {:map, x}
      after
        0 -> :timeout
      end
    end
    """

    mutators = [
      Mutare.Mutators.IntegerLiteral,
      Mutare.Mutators.Relational,
      Mutare.Mutators.PatternSwap,
      Mutare.Mutators.PatternWildcard,
      Mutare.Mutators.GuardDrop
    ]

    {module, sites, _} = compile_fixture(:Equivalence, body, mutators)
    source = source(module, body)

    for family <- [:integer, :relational, :pattern_swap, :pattern_wildcard, :guard_drop],
        do: assert(Enum.any?(sites, &(&1.mutator == family)))

    terms = [:early, :unmatched, 0, 1, 2, 5, 6, {1, 1}, {1, 2}, "text", %{}]

    queues =
      [[], [:unmatched, 2, 1, 2], [{1, 2}, :early, {1, 1}]] ++
        for a <- terms, b <- terms, do: [a, b]

    for site <- [nil | sites] do
      patched =
        if site,
          do: Sourceror.patch_string(source, [%{range: site.range, change: site.mutated_code}]),
          else: source

      {:defmodule, _, [_, [do: {:def, _, [_, [do: expression]]}]]} =
        Code.string_to_quoted!(patched)

      expected = eval_fun(expression)
      Selector.put(if site, do: site.id, else: 999_999)

      for messages <- queues do
        assert run_mailbox(fn -> apply(module, :take, []) end, messages) ==
                 run_mailbox(expected, messages),
               "mutant #{inspect(site && site.id)}, mailbox #{inspect(messages)}"
      end
    end
  end

  test "message order takes precedence over clause order, and later variants stay behind earlier originals" do
    {module, sites, _} =
      compile_fixture(
        :Order,
        "def take, do: (receive do 1 -> :one; 2 -> :two after 0 -> :timeout end)"
      )

    take = fn -> apply(module, :take, []) end
    assert run_mailbox(take, [:unmatched, 2, 1]) == {{:ok, :two}, [:unmatched, 1]}

    Selector.put(site(sites, "1", "2").id)
    assert run_mailbox(take, [:unmatched, 1, 2, 3]) == {{:ok, :one}, [:unmatched, 1, 3]}
    assert run_mailbox(take, [:unmatched, 1]) == {{:ok, :timeout}, [:unmatched, 1]}

    Selector.put(site(sites, "2", "1").id)
    assert run_mailbox(take, [2, 1, :unmatched]) == {{:ok, :one}, [2, :unmatched]}
  end

  test "selection is fixed before evaluating the timeout and while waiting for new messages" do
    {module, sites, _} =
      compile_fixture(:Waiting, """
      def take(timeout) do
        receive do
          1 -> :one
          2 -> :two
        after
          timeout.() -> :timeout
        end
      end
      """)

    parent = self()
    retarget = site(sites, "1", "2").id

    for {initial, later, reply} <- [{0, retarget, :two}, {retarget, 0, :one}] do
      Selector.put(initial)

      timeout = fn ->
        send(parent, {:waiting, self()})
        :infinity
      end

      handle =
        {pid, _, _} = start_mailbox(fn -> apply(module, :take, [timeout]) end, [:unmatched])

      assert_receive {:waiting, ^pid}
      Selector.put(later)
      send(pid, :still_unmatched)
      send(pid, 2)
      assert await_mailbox(handle) == {{:ok, reply}, [:unmatched, :still_unmatched]}
    end
  end

  test "a receive without after keeps unmatched messages while waiting for a pinned match" do
    {module, sites, metamutant} =
      compile_fixture(:Pinned, """
      def take(ref, entered) do
        entered.()
        receive do
          {^ref, 1} -> :one
          {^ref, 2} -> :two
        end
      end
      """)

    assert [{_, nil}] = receives(metamutant)
    ref = make_ref()
    other = make_ref()
    parent = self()
    Selector.put(site(sites, "1", "2").id)
    entered = fn -> send(parent, {:entered, self()}) end

    handle =
      {pid, _, _} = start_mailbox(fn -> apply(module, :take, [ref, entered]) end, [{other, 2}])

    assert_receive {:entered, ^pid}
    Selector.put(Selector.baseline())
    send(pid, {ref, 1})
    send(pid, {ref, 2})
    assert await_mailbox(handle) == {{:ok, :one}, [{other, 2}, {ref, 1}]}
  end

  test "coverage records once before timeout evaluation, then only in the selected body" do
    {module, sites, _} =
      compile_fixture(:Coverage, """
      def take(timeout) do
        receive do
          1 -> 100
          2 -> 200
        after
          timeout.() -> 300
        end
      end
      """)

    ids_for = fn codes -> for s <- sites, s.original_code in codes, do: s.id end
    heads = ids_for.(["1", "2"])
    parent = self()
    :persistent_term.put(Recorder.track_key(), true)

    for {messages, value, body_ids} <- [
          {[1, 2], 100, ids_for.(["100"])},
          {[:unmatched], 300, ids_for.(["300"])}
        ] do
      timeout = fn ->
        send(parent, {:timeout_evaluated, self()})
        0
      end

      handle = {pid, _, _} = start_mailbox(fn -> apply(module, :take, [timeout]) end, messages)
      assert_receive first
      assert first == {:covered, pid, heads}
      assert_receive second
      assert second == {:timeout_evaluated, pid}
      assert_receive third
      assert third == {:covered, pid, body_ids}
      assert {{:ok, ^value}, _} = await_mailbox(handle)
      refute_received {:covered, ^pid, _}
      refute_received {:timeout_evaluated, ^pid}
    end

    Selector.put(site(sites, "1", "2").id)
    assert run_mailbox(fn -> apply(module, :take, [fn -> 0 end]) end, [2]) == {{:ok, 100}, []}
    refute_received {:covered, _, _}
    assert run_mailbox(fn -> apply(module, :take, [fn -> 0 end]) end, [1]) == {{:ok, 300}, [1]}
    refute_received {:covered, _, _}
  end

  test "timeout expression runs exactly once, including invalid and raising timeouts" do
    {module, sites, _} =
      compile_fixture(:Timeouts, """
      def take(timeout) do
        receive do 1 -> :one after timeout.() -> :timeout end
      end
      """)

    parent = self()
    :persistent_term.put(Recorder.track_key(), true)
    heads = Enum.map(sites, & &1.id)

    for value <- [0, 1, :infinity, -1, :invalid, :raise] do
      callback = fn ->
        send(parent, {:timeout_evaluated, self()})
        if value == :raise, do: raise("timeout callback"), else: value
      end

      handle = {pid, _, _} = start_mailbox(fn -> apply(module, :take, [callback]) end, [1])
      assert_receive first
      assert first == {:covered, pid, heads}
      actual = await_mailbox(handle)
      assert_received {:timeout_evaluated, ^pid}
      refute_received {:timeout_evaluated, ^pid}

      expected =
        run_mailbox(
          fn ->
            receive do
              1 -> :one
            after
              callback.() -> :timeout
            end
          end,
          [1]
        )

      assert actual == expected
      assert_receive {:timeout_evaluated, _}
    end
  end

  test "unmatched arrivals do not restart a finite timeout" do
    {module, sites, _} =
      compile_fixture(:Deadline, """
      def take(timeout) do
        receive do 1 -> :one after timeout.() -> :timeout end
      end
      """)

    parent = self()
    Selector.put(site(sites, "1", "2").id)

    timeout = fn ->
      send(parent, {:waiting, self()})
      40
    end

    handle = {pid, _, _} = start_mailbox(fn -> apply(module, :take, [timeout]) end, [1])
    assert_receive {:waiting, ^pid}
    sender = spawn_link(fn -> send_noise(pid) end)
    on_exit(fn -> if Process.alive?(sender), do: Process.exit(sender, :kill) end)
    started = System.monotonic_time(:millisecond)
    assert {{:ok, :timeout}, [1 | noise]} = await_mailbox(handle, 1_000)
    send(sender, :stop)
    assert Enum.all?(noise, &(&1 == :noise))
    assert System.monotonic_time(:millisecond) - started < 1_000
    refute_received {:waiting, ^pid}
  end

  test "body and after mutants remain independent of head mutants" do
    {module, sites, _} =
      compile_fixture(:Bodies, "def take, do: (receive do 1 -> 100; 2 -> 200 after 0 -> 300 end)")

    take = fn -> apply(module, :take, []) end

    for {original, replacement, input, expected} <- [
          {"100", "101", [1, 2], 101},
          {"200", "201", [2, 1], 201},
          {"300", "301", [], 301}
        ] do
      Selector.put(site(sites, original, replacement).id)
      assert {{:ok, ^expected}, _} = run_mailbox(take, input)
    end

    Selector.put(site(sites, "1", "2").id)
    assert run_mailbox(take, [2]) == {{:ok, 100}, []}
    assert run_mailbox(take, [1]) == {{:ok, 300}, [1]}
  end

  test "keyword receives and after-only receives keep their block semantics" do
    {module, sites, metamutant} =
      compile_fixture(:Keyword, """
      def take, do: receive(do: (1 -> :one; 2 -> :two), after: (0 -> :timeout))
      def delay, do: receive(after: (0 -> 100))
      """)

    assert length(receives(metamutant)) == 2
    Selector.put(site(sites, "1", "2").id)

    assert run_mailbox(fn -> apply(module, :take, []) end, [:unmatched, 2]) ==
             {{:ok, :one}, [:unmatched]}

    Selector.put(site(sites, "100", "101").id)
    assert run_mailbox(fn -> apply(module, :delay, []) end, [1, 2]) == {{:ok, 101}, [1, 2]}
  end

  test "macro-visible source bindings survive in original, mutant and after bodies" do
    {module, sites, _} =
      compile_fixture(:Bindings, """
      defmacro scope, do: Macro.escape(Macro.Env.vars(__CALLER__))
      def take(mutare_active) do
        result = receive do
          {1, x} -> {binding(), scope()}
          {2, x} -> {binding(), scope()}
        after
          0 -> {binding(), scope()}
        end
        {result, binding(), scope()}
      end
      """)

    for id <- [0 | Enum.map(sites, & &1.id)],
        messages <- [[], [{1, :payload}], [{2, :payload}]] do
      Selector.put(id)

      assert {{:ok, {{inside, vars}, outside, outer_vars}}, _} =
               run_mailbox(fn -> apply(module, :take, [:source]) end, messages)

      assert inside[:mutare_active] == :source
      assert inside[:mutare_active_0] == id
      assert Enum.sort(Keyword.keys(inside)) == Enum.sort(Keyword.keys(vars))

      assert Enum.sort(Keyword.keys(inside)) in [
               [:mutare_active, :mutare_active_0],
               [:mutare_active, :mutare_active_0, :x]
             ]

      if Keyword.has_key?(inside, :x), do: assert(inside[:x] == :payload)
      assert Enum.sort(Keyword.keys(outer_vars)) == [:mutare_active, :mutare_active_0, :result]
      assert Enum.sort(Keyword.keys(outside)) == [:mutare_active, :mutare_active_0, :result]
    end
  end

  test "head mutants run raw fallthrough and after bodies; the baseline keeps the instrumented ones" do
    {module, sites, metamutant} =
      compile_fixture(
        :RawFallthrough,
        """
        defmacro stage(value) do
          vars = Macro.escape(Macro.Env.vars(__CALLER__))
          quote do: {unquote(value), unquote(vars)}
        end
        def take(x) do
          receive do
            1 -> :one
            _ -> x |> stage()
          after
            0 -> x |> stage()
          end
        end
        """,
        [StageSwap, Mutare.Mutators.IntegerLiteral]
      )

    heads = Enum.filter(sites, &(&1.mutator == :integer))
    assert length(heads) == 2
    # `:one` is shared as-is; the instrumented fallthrough and after bodies each select.
    assert [{clauses, [_after_clause]}] = receives(metamutant)
    assert length(clauses) == 2 + length(heads)
    assert length(String.split(metamutant, "case mutare_active do")) == 5

    instrumented = {3, [mutare_active: nil, mutare_piped: nil, x: nil]}
    raw = {3, [mutare_active: nil, x: nil]}
    take = fn messages -> run_mailbox(fn -> apply(module, :take, [3]) end, messages) end
    assert take.([1]) == {{:ok, :one}, []}
    assert take.([9]) == {{:ok, instrumented}, []}
    assert take.([]) == {{:ok, instrumented}, []}

    for site <- heads do
      Selector.put(site.id)
      assert take.([1]) == {{:ok, raw}, []}
      assert take.([9]) == {{:ok, raw}, []}
      assert take.([]) == {{:ok, raw}, []}
      {mutated, _} = Code.eval_string(site.mutated_code)
      assert take.([mutated]) == {{:ok, :one}, []}
    end
  end

  test "unbound rescue scopes retain raw mutant bindings in message and after bodies" do
    {module, sites, metamutant} =
      compile_fixture(:Fallback, """
      defmacro scope, do: Macro.escape(Macro.Env.vars(__CALLER__))
      def take do
        raise "enter rescue"
      rescue
        _ -> receive do 1 -> scope(); 2 -> scope() after 0 -> scope() end
      end
      """)

    assert length(receives(metamutant)) == 1 + length(sites)

    assert run_mailbox(fn -> apply(module, :take, []) end, [1]) ==
             {{:ok, [mutare_active: nil]}, []}

    Selector.put(site(sites, "1", "2").id)
    assert run_mailbox(fn -> apply(module, :take, []) end, [1, 2]) == {{:ok, []}, [1]}
    assert run_mailbox(fn -> apply(module, :take, []) end, [1]) == {{:ok, []}, [1]}
  end

  test "whole-node mutations keep their ids and bypass mailbox and timeout evaluation" do
    {module, sites, _} =
      compile_fixture(
        :Whole,
        "def take(timeout), do: (receive do 1 -> :one after timeout.() -> :timeout end)",
        [WholeReceive, Mutare.Mutators.IntegerLiteral]
      )

    assert [%{mutator: :whole_receive} = whole | heads] = sites
    assert Enum.all?(heads, &(&1.mutator == :integer))
    Selector.put(whole.id)

    assert run_mailbox(fn -> apply(module, :take, [fn -> raise "must not evaluate" end]) end, [1]) ==
             {{:ok, :replaced}, [1]}
  end

  test "unbound receive head mutants keep raw scope alongside whole-node mutants" do
    {module, sites, metamutant} =
      compile_fixture(
        :RescueScope,
        """
        defmacro scope, do: Macro.escape(Macro.Env.vars(__CALLER__))
        def take do
          raise "enter rescue"
        rescue
          _ -> receive do 1 -> scope(); 2 -> scope() after 0 -> scope() end
        end
        """,
        [WholeReceive, Mutare.Mutators.IntegerLiteral]
      )

    assert coverage_payloads(metamutant) == [Enum.map(sites, & &1.id)]
    take = fn -> apply(module, :take, []) end
    assert run_mailbox(take, [1]) == {{:ok, [mutare_active: nil]}, []}
    Selector.put(site(sites, "1", "2").id)
    assert run_mailbox(take, [1, 2]) == {{:ok, []}, [1]}
    assert run_mailbox(take, [1]) == {{:ok, []}, [1]}

    whole = Enum.find(sites, &(&1.mutator == :whole_receive))
    Selector.put(whole.id)
    assert run_mailbox(take, [1]) == {{:ok, :replaced}, [1]}
  end

  test "nested module receives do not reference the enclosing function's selector" do
    nested = Module.concat(__MODULE__, :Nested)

    {module, sites, metamutant} =
      compile_fixture(:NestedOwner, """
      def build do
        defmodule Elixir.#{inspect(nested)} do
          def take do
            receive do 1 -> :one; 2 -> :two after 0 -> :timeout end
          end
        end
      end
      """)

    assert length(receives(metamutant)) == 1 + length(sites)
    ExUnit.CaptureIO.capture_io(:stderr, fn -> apply(module, :build, []) end)

    on_exit(fn ->
      :code.purge(nested)
      :code.delete(nested)
    end)

    Selector.put(site(sites, "1", "2").id)
    assert run_mailbox(fn -> apply(nested, :take, []) end, [1, 2]) == {{:ok, :one}, [1]}
  end

  test "withholding every head variant retains body mutations and the original receive" do
    module = Module.concat(__MODULE__, :OnlyBody)
    source = source(module, "def take, do: (receive do 1 -> 100 after 0 -> 200 end)")
    opts = [mutators: [Mutare.Mutators.IntegerLiteral]]
    %{sites: sites, next_id: next} = Transform.transform_string_with_sites(source, opts)
    selected = site(sites, "100", "101")

    %{metamutant: metamutant, next_id: ^next} =
      Transform.transform_string_with_sites(source, opts ++ [emit_ids: MapSet.new([selected.id])])

    assert [{[_clause], [_after_clause]}] = receives(metamutant)
    assert coverage_payloads(metamutant) == [[selected.id]]
    compile_observed(module, metamutant, CoverageSink)
    Selector.put(selected.id)
    assert run_mailbox(fn -> apply(module, :take, []) end, [1]) == {{:ok, 101}, []}
    assert run_mailbox(fn -> apply(module, :take, []) end, [2]) == {{:ok, 200}, [2]}
  end

  test "ignores, poison skips and selection preserve ids and emit only live clauses" do
    body = """
    def take do
      receive do
      1 -> :one # mutare:ignore[integer:zero] intentional
      2 -> :two
      3 -> :three
    after
      0 -> :timeout
    end
    end
    """

    module = Module.concat(__MODULE__, :Filtered)
    source = source(module, body)
    opts = [mutators: [Mutare.Mutators.IntegerLiteral], start_id: 50]
    %{sites: original, next_id: next} = Transform.transform_string_with_sites(source, opts)
    skipped = site(original, "2", "3").id
    selected = for s <- original, s.original_code != "3", into: MapSet.new(), do: s.id
    filtered = opts ++ [skip_ids: MapSet.new([skipped]), emit_ids: selected]

    %{metamutant: metamutant, sites: sites, next_id: ^next} =
      Transform.transform_string_with_sites(source, filtered)

    assert Enum.map(sites, &{&1.id, &1.range}) == Enum.map(original, &{&1.id, &1.range})
    assert Transform.count_string(source, filtered) == length(sites)
    live = for s <- sites, not s.ignored and not s.poisoned and s.id in selected, do: s.id
    assert coverage_payloads(metamutant) == [live]
    assert [{clauses, [_]}] = receives(metamutant)
    assert length(clauses) == 3 + length(live)
    compile_observed(module, metamutant, CoverageSink)

    for id <- [skipped | Enum.map(Enum.filter(sites, & &1.ignored), & &1.id)] do
      Selector.put(id)
      assert run_mailbox(fn -> apply(module, :take, []) end, [2, 1, 3]) == {{:ok, :two}, [1, 3]}
    end

    %{metamutant: unchanged, next_id: ^next} =
      Transform.transform_string_with_sites(source, opts ++ [emit_ids: MapSet.new()])

    assert unchanged == source
  end

  test "manifest attributes poisoned receive guards and the whole-receive fallback" do
    module = Module.concat(__MODULE__, :Poison)

    source =
      source(
        module,
        "def take(mutare_active), do: (receive do x when x > 5 -> x after 0 -> :timeout end)"
      )

    opts = [mutators: [PoisonGuard, Mutare.Mutators.IntegerLiteral]]

    %{metamutant: metamutant, sites: sites, next_id: next, dispatch_var: var} =
      Transform.transform_string_with_sites(source, opts)

    poison = Enum.find(sites, &(&1.mutator == :poison_receive_guard))
    manifest = Manifest.from_source(metamutant, var)
    assert Manifest.ids_at_line(manifest, line_of(metamutant, "Map.new(x)")) == [poison.id]

    assert Enum.sort(Manifest.ids_at_line(manifest, line_of(metamutant, "receive do"))) ==
             Enum.map(sites, & &1.id)

    assert_compile_error(metamutant)

    %{metamutant: recovered, next_id: ^next} =
      Transform.transform_string_with_sites(source, opts ++ [skip_ids: MapSet.new([poison.id])])

    compile_observed(module, recovered, CoverageSink)
    assert run_mailbox(fn -> apply(module, :take, [:source]) end, [6, 1]) == {{:ok, 6}, [1]}
  end

  defp start_mailbox(fun, messages) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:receive_coverage_observer, parent)
        Enum.each(messages, &send(self(), &1))

        result =
          try do
            {:ok, fun.()}
          rescue
            error -> {:raised, error.__struct__, Exception.message(error)}
          end

        {:messages, remaining} = Process.info(self(), :messages)
        send(parent, {ref, result, remaining})
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {pid, ref, monitor}
  end

  defp await_mailbox({pid, ref, monitor}, timeout \\ 1_000) do
    assert_receive {^ref, result, remaining}, timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, timeout
    {result, remaining}
  end

  defp run_mailbox(fun, messages), do: await_mailbox(start_mailbox(fun, messages))

  defp send_noise(pid) do
    receive do
      :stop -> :ok
    after
      5 ->
        send(pid, :noise)
        send_noise(pid)
    end
  end

  defp eval_fun(expression) do
    ast = {:fn, [], [{:->, [], [[], expression]}]}

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      {fun, _} = Code.eval_quoted(ast)
      send(self(), {:reference_fun, fun})
    end)

    assert_received {:reference_fun, fun}
    fun
  end

  defp site(sites, original, mutated) do
    found = Enum.find(sites, &(&1.original_code == original and &1.mutated_code == mutated))
    assert found, "missing #{original} -> #{mutated}"
    found
  end

  defp source(module, body), do: "defmodule #{inspect(module)} do\n#{body}\nend"

  defp compile_fixture(name, body, mutators \\ [Mutare.Mutators.IntegerLiteral]) do
    module = Module.concat(__MODULE__, name)

    %{metamutant: metamutant, sites: sites} =
      Transform.transform_string_with_sites(source(module, body), mutators: mutators)

    compile_observed(module, metamutant, CoverageSink)
    {module, sites, metamutant}
  end

  defp receives(source) do
    {_, nodes} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:receive, _, [blocks]} = node, acc ->
          {node, [{Keyword.get(blocks, :do), Keyword.get(blocks, :after)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(nodes)
  end

  defp coverage_payloads(source) do
    helper = Recorder.fixture_module()

    {_, payloads} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [^helper, :hit]}, _, [ids]} = node, acc -> {node, [ids | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(payloads)
  end

  defp line_of(source, fragment),
    do: Enum.find_index(String.split(source, "\n"), &String.contains?(&1, fragment)) + 1
end
