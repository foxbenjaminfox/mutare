defmodule Mutare.TransformDurationTest do
  # Duration/timeout-argument suppression, the flagship user of the general argument-marking facility
  # (`Mutare.Transform.Resolve.ArgumentMarks` + `c:Mutare.Mutator.argument_marks/1`): `IntegerLiteral` and
  # `AtomLiteral` ask the transform to mark the timeout positions with the `:timeout` label and
  # decline there, so a *literal* duration (an integer count of milliseconds, or `:infinity`) is left
  # unmutated — a near-unkillable equivalent mutant — while a *computed* duration, and every other
  # argument, still mutates. Resolution rides on the same reader the call families use, so aliased /
  # imported / Erlang-atom forms are recognised and a shadowing alias is not. The last two `describe`s
  # exercise the facility itself — with a custom mutator's own label, and through the user-facing
  # `argument_marks:` option that extends any declared label's table from configuration.
  use ExUnit.Case, async: true
  import Mutare.Test.Metamutant

  # A third-party mutator exercising the general facility: it marks argument 1 of `Widget.render/2`
  # (and the `:mode` option of `Widget.stream/2`) with its *own* label, and declines integer
  # mutations there — nothing timeout-specific, and a function core knows nothing about.
  defmodule MarkingMutator do
    @behaviour Mutare.Mutator
    @impl true
    def name, do: :marking

    @impl true
    def argument_marks(_config) do
      [
        {Widget, :render, 2, [1], :pinned},
        {Widget, :stream, 2, [{:keyword, :mode}], :pinned}
      ]
    end

    @impl true
    def mutate(node, context) do
      if Mutare.Mutator.marked?(context, :pinned), do: :skip, else: mutate(node)
    end

    @impl true
    def mutate({:__block__, _meta, [n]}) when is_integer(n), do: [Mutare.AST.literal(n + 1)]
    def mutate(_node), do: :skip
  end

  # The two value families that would otherwise fire on a duration literal: Literal on an integer
  # (succ/pred/zero), AtomLiteral on `:infinity` (→ the sentinel).
  @value [Mutare.Mutators.IntegerLiteral, Mutare.Mutators.AtomLiteral]

  # A distinctive marker used as the duration literal in the table-coverage test below — improbable
  # elsewhere, so "no site whose original is `13579`" is an exact "the duration was held back" check.
  @marker "13579"

  # One representative call per row of `IntegerLiteral`'s timeout tables, with `@marker` in the duration
  # position. Exercised by the "every table row" test so a typo'd row (wrong arity/index/module/fun)
  # is caught — the per-mechanism tests below can't see that, since they only touch a few rows.
  @duration_call_rows [
    # positional
    "Process.sleep(#{@marker})",
    ":timer.sleep(#{@marker})",
    "Process.send_after(pid, msg, #{@marker})",
    "Process.send_after(pid, msg, #{@marker}, abs: true)",
    "GenServer.call(pid, msg, #{@marker})",
    "GenServer.multi_call(ts, sup, msg, #{@marker})",
    "GenServer.stop(pid, :normal, #{@marker})",
    "Agent.get(pid, fun, #{@marker})",
    "Agent.get(pid, IO, :puts, [], #{@marker})",
    "Agent.get_and_update(pid, fun, #{@marker})",
    "Agent.get_and_update(pid, IO, :puts, [], #{@marker})",
    "Agent.update(pid, fun, #{@marker})",
    "Agent.update(pid, IO, :puts, [], #{@marker})",
    "Agent.stop(pid, :normal, #{@marker})",
    "Supervisor.stop(sup, :normal, #{@marker})",
    "DynamicSupervisor.stop(sup, :normal, #{@marker})",
    "Task.await(t, #{@marker})",
    "Task.await_many(ts, #{@marker})",
    "Task.yield(t, #{@marker})",
    "Task.yield_many(ts, #{@marker})",
    "Task.shutdown(t, #{@marker})",
    # duration constructors
    ":timer.seconds(#{@marker})",
    ":timer.minutes(#{@marker})",
    ":timer.hours(#{@marker})",
    ":timer.hms(0, 0, #{@marker})",
    # :timer scheduling functions (delay is arg 0)
    ":timer.apply_after(#{@marker}, fun)",
    ":timer.apply_after(#{@marker}, IO, :puts, [])",
    ":timer.apply_interval(#{@marker}, fun)",
    ":timer.apply_interval(#{@marker}, IO, :puts, [])",
    ":timer.send_after(#{@marker}, msg)",
    ":timer.send_after(#{@marker}, pid, msg)",
    ":timer.send_interval(#{@marker}, msg)",
    ":timer.send_interval(#{@marker}, pid, msg)",
    ":timer.exit_after(#{@marker}, :reason)",
    ":timer.exit_after(#{@marker}, pid, :reason)",
    ":timer.kill_after(#{@marker})",
    ":timer.kill_after(#{@marker}, pid)",
    # keyword
    "Task.async_stream(e, fun, timeout: #{@marker})",
    "Task.Supervisor.async_stream(sup, e, fun, timeout: #{@marker})",
    "Task.Supervisor.async_stream_nolink(sup, e, fun, timeout: #{@marker})",
    "Task.yield_many(ts, timeout: #{@marker})"
  ]

  describe "every duration table row is covered (guards each row against typos)" do
    test "each table entry holds its duration literal back, and the metamutant compiles" do
      for call <- @duration_call_rows do
        {meta, triples} =
          value_triples("def f(pid, msg, t, ts, e, fun, sup), do: #{call}")

        refute Enum.any?(triples, fn {_m, original, _} -> original == @marker end),
               "expected the duration literal in `#{call}` to be held back, got: #{inspect(triples)}"

        assert_compiles(meta)
      end
    end

    test "the marker literal DOES mutate where it is not a duration position (not a vacuous check)" do
      # `String.slice(s, 0, 13579)` is not a timeout call, so the same marker mutates fully — proving
      # the row test above asserts a real suppression, not just an absent mutation.
      {_meta, triples} = value_triples("def f(s), do: String.slice(s, 0, #{@marker})")

      assert Enum.any?(triples, fn {m, original, _} -> m == :integer and original == @marker end)
    end

    test "a non-duration atom in the duration position still mutates (value-shaped, not blanket)" do
      # `Task.shutdown/2`'s second arg is `timeout() | :brutal_kill`: an integer/`:infinity` is held
      # back, but `:brutal_kill` is not a duration value, so it still mutates — the suppression keys
      # on the *literal shape* at the position, not the position alone.
      {meta, triples} = value_triples("def f(t), do: Task.shutdown(t, :brutal_kill)")

      assert {:atom, ":brutal_kill", ":mutare"} in triples
      assert_compiles(meta)
    end
  end

  describe "positional duration arguments are left raw" do
    test "Process.sleep/1, :timer.sleep/1, and send_after's time arg mint no literal mutant" do
      for body <- [
            "def f, do: Process.sleep(1000)",
            "def f, do: :timer.sleep(500)",
            "def f(pid, msg), do: Process.send_after(pid, msg, 5_000)"
          ] do
        {meta, triples} = value_triples(body)
        assert triples == []
        assert_compiles(meta)
      end
    end

    test "GenServer.call's timeout is suppressed only at the arity that carries one" do
      # /3 has a timeout at index 2 → suppressed; /2 has none → nothing to suppress (and no
      # literal to mutate anyway), so both simply yield no literal mutant here.
      assert value_triples("def f(pid, msg), do: GenServer.call(pid, msg, 5000)") |> elem(1) == []
      assert value_triples("def f(pid, msg), do: GenServer.call(pid, msg)") |> elem(1) == []
    end

    test "an :infinity timeout is not swapped to the sentinel, but a sibling non-duration atom is" do
      # `GenServer.stop(server, reason, timeout)`: the `:infinity` *timeout* (index 2) is a
      # duration and suppressed; the `:normal` *reason* (index 1) is an ordinary atom and still
      # mutates — the suppression is positional, not "every atom in the call".
      {meta, triples} = value_triples("def f(s), do: GenServer.stop(s, :normal, :infinity)")

      assert triples == [{:atom, ":normal", ":mutare"}]
      refute Enum.any?(triples, fn {_m, o, _} -> o == ":infinity" end)
      assert_compiles(meta)
    end

    test "a computed duration still mutates — suppression is literal-only" do
      # `base * 2` is not a literal, so it descends and mutates normally (the `2` factor is not a
      # duration count — it is genuine arithmetic the suite may pin down).
      {meta, triples} = value_triples("def f(base), do: Process.sleep(base * 2)")

      assert {:integer, "2", "3"} in triples
      assert {:integer, "2", "1"} in triples
      assert {:integer, "2", "0"} in triples
      assert_compiles(meta)
    end

    test "a same-named function on another module is untouched" do
      # `String.slice(s, 0, 1000)` is not a timeout position, so both integer literals mutate —
      # the table is keyed on the resolved `{module, function, arity}`, not the bare name.
      {_meta, triples} = value_triples("def f(s), do: String.slice(s, 0, 1000)")

      assert {:integer, "1000", "999"} in triples
      assert {:integer, "0", "1"} in triples
    end

    test ":timer duration constructors leave every magnitude argument alone" do
      # `:timer.seconds/minutes/hours` are `N * 1000/60000/…`: the argument is a duration magnitude
      # wherever the result flows, so it is held back just like a bare millisecond literal — closing
      # the gap where `Process.sleep(:timer.seconds(5))` would otherwise mutate the `5` that
      # `Process.sleep(5000)` does not. `:timer.hms/3` holds back all three (h, m, s).
      for body <- [
            "def f, do: :timer.seconds(5)",
            "def f, do: :timer.minutes(1)",
            "def f, do: :timer.hours(2)",
            "def f, do: :timer.hms(0, 1, 30)",
            "def f, do: Process.sleep(:timer.seconds(5))"
          ] do
        {meta, triples} = value_triples(body)
        assert triples == []
        assert_compiles(meta)
      end

      # A *computed* magnitude still mutates — only the bare literal at the position is held back.
      {_m, computed} = value_triples("def f(n), do: :timer.seconds(n * 2)")
      assert {:integer, "2", "1"} in computed
    end

    test ":timer scheduling functions hold back only the delay (arg 0), not the message" do
      # The delay is `:timer`'s *first* argument (unlike `Process.send_after`'s third), so a literal
      # message/reason elsewhere still mutates.
      {_m, triples} = value_triples("def f(p), do: :timer.send_after(1000, p, 999)")

      refute Enum.any?(triples, fn {_m, o, _} -> o == "1000" end)
      assert {:integer, "999", "0"} in triples
    end
  end

  describe "keyword duration options are left raw" do
    test "Task.async_stream's :timeout value is suppressed while its neighbours still mutate" do
      {meta, triples} =
        value_triples(
          "def f(e, fun), do: Task.async_stream(e, fun, timeout: 5000, max_concurrency: 4)"
        )

      # The `:timeout` *value* mints no literal mutant…
      refute Enum.any?(triples, fn {m, o, _} -> m == :integer and o == "5000" end)
      # …while a neighbouring option's value (`max_concurrency: 4`) still mutates fully…
      assert {:integer, "4", "3"} in triples
      # …and the option *keys* mutate as any call-option key would (the value, not the key, is
      # the duration).
      assert {:atom, "timeout:", "mutare:"} in triples
      assert_compiles(meta)
    end

    test "an explicit `[timeout: …]` list is suppressed like the keyword sugar" do
      # `Task.async_stream(e, fun, [timeout: 5000, …])` — the same options as the trailing-keyword
      # sugar, but Sourceror wraps the explicit list in a single-element `__block__`. The value is
      # still held back, the neighbour still mutates, and the rendered list keeps its shape.
      {meta, triples} =
        value_triples(
          "def f(e, fun), do: Task.async_stream(e, fun, [timeout: 5000, max_concurrency: 4])"
        )

      refute Enum.any?(triples, fn {m, o, _} -> m == :integer and o == "5000" end)
      assert {:integer, "4", "3"} in triples
      assert_compiles(meta)
    end

    test "Task.yield_many accepts its timeout as a bare arg OR an option — both are suppressed" do
      # Per its two specs, `yield_many/2`'s second argument is either a bare `timeout()` or an
      # options keyword — so it is in *both* tables, and every spelling holds the duration back
      # (a bare `5000`/`:infinity`, the `timeout:` sugar, and the explicit `[timeout: …]` list),
      # while a neighbouring `:limit` count still mutates.
      for body <- [
            "def f(ts), do: Task.yield_many(ts, 5000)",
            "def f(ts), do: Task.yield_many(ts, :infinity)",
            "def f(ts), do: ts |> Task.yield_many(5000)"
          ] do
        {meta, triples} = value_triples(body)
        assert triples == []
        assert_compiles(meta)
      end

      for body <- [
            "def f(ts), do: Task.yield_many(ts, timeout: 5000, limit: 2)",
            "def f(ts), do: Task.yield_many(ts, [timeout: 5000, limit: 2])"
          ] do
        {meta, triples} = value_triples(body)
        refute Enum.any?(triples, fn {m, o, _} -> m == :integer and o == "5000" end)
        assert {:integer, "2", "1"} in triples
        assert_compiles(meta)
      end
    end
  end

  describe "arity discrimination: only options-bearing arities carry the :timeout option" do
    # `Task.async_stream` and `Task.Supervisor.async_stream` have an MFA form whose trailing
    # argument is the callback `args` *list*, not stream options — so a keyword-shaped literal there
    # is ordinary data and must still mutate. The keyword table is keyed by arity for exactly this.
    test "async_stream/4 MFA form: the trailing args list is data, so its literal mutates" do
      # `Task.async_stream(enum, Mod, :run, [timeout: 5000])` is the /4 MFA form — `[timeout: 5000]`
      # is passed as arguments to `Mod.run`, not as stream options, so `5000` is a real literal.
      {meta, triples} =
        value_triples("def f(enum), do: Task.async_stream(enum, Mod, :run, [timeout: 5000])")

      assert {:integer, "5000", "0"} in triples
      assert_compiles(meta)
    end

    test "async_stream/5 MFA form: the trailing list IS options, so :timeout is suppressed" do
      # The /5 MFA form `(enum, module, function, args, options)` — now the trailing list is genuine
      # options, so the timeout is held back while the `args` list (`[1, 2]`) still mutates.
      {meta, triples} =
        value_triples(
          "def f(enum), do: Task.async_stream(enum, Mod, :run, [1, 2], timeout: 5000)"
        )

      refute Enum.any?(triples, fn {m, o, _} -> m == :integer and o == "5000" end)
      assert {:integer, "1", "2"} in triples
      assert_compiles(meta)
    end

    test "Task.Supervisor.async_stream distinguishes its /5 (data) and /6 (options) arities" do
      # /5 MFA `(supervisor, enumerable, module, function, args)` — trailing list is `args` data.
      {_m, data} =
        value_triples(
          "def f(sup, enum), do: Task.Supervisor.async_stream(sup, enum, Mod, :run, [timeout: 5000])"
        )

      assert {:integer, "5000", "0"} in data

      # /6 MFA `(…, args, options)` — trailing list is options, so the timeout is suppressed.
      {_m, opts} =
        value_triples(
          "def f(sup, enum), do: Task.Supervisor.async_stream(sup, enum, Mod, :run, [1], timeout: 5000)"
        )

      refute Enum.any?(opts, fn {m, o, _} -> m == :integer and o == "5000" end)
    end

    test "async_stream_nolink is covered like its linked twin, with the same /5-vs-/6 split" do
      # The unlinked variant shares async_stream's options surface: /6 options are suppressed, /5
      # MFA `args` data still mutates.
      {_m, opts} =
        value_triples(
          "def f(sup, enum, fun), do: Task.Supervisor.async_stream_nolink(sup, enum, fun, timeout: 5000)"
        )

      refute Enum.any?(opts, fn {m, o, _} -> m == :integer and o == "5000" end)

      {_m, data} =
        value_triples(
          "def f(sup, enum), do: Task.Supervisor.async_stream_nolink(sup, enum, Mod, :run, [timeout: 5000])"
        )

      assert {:integer, "5000", "0"} in data
    end

    test "GenServer.multi_call carries a timeout only at /4, not /3 (whose 3rd arg is the request)" do
      # `multi_call(nodes, name, request, timeout)` — /4 index 3 is the timeout, suppressed…
      {_m, four} =
        value_triples("def f(n, req), do: GenServer.multi_call(n, MyServer, req, 5000)")

      refute Enum.any?(four, fn {m, o, _} -> m == :integer and o == "5000" end)

      # …but `multi_call(nodes, name, request)` /3's third arg is the *request*, so a literal there
      # (Elixir fills the leading `nodes` default, not the trailing `timeout`) still mutates.
      {_m, three} = value_triples("def f(n), do: GenServer.multi_call(n, MyServer, 5000)")
      assert {:integer, "5000", "0"} in three
    end

    test "Agent's MFA form marks the timeout (/5 index 4), not the args list (/4)" do
      # `Agent.get(agent, module, fun, args, timeout)` — the timeout is suppressed…
      {_m, with_to} = value_triples("def f(a), do: Agent.get(a, Mod, :run, [1], 5000)")
      refute Enum.any?(with_to, fn {m, o, _} -> m == :integer and o == "5000" end)
      # …while a literal inside the `args` list (the /4 form has no timeout) still mutates.
      assert {:integer, "1", "0"} in with_to
    end
  end

  describe "scoping: only the duration value is suppressed, not the options list itself" do
    # The suppression must not leak into unrelated mutations of the options list — otherwise a call
    # would behave differently just for being in the timeout table. These pin that a table call's
    # options list gets the exact same list-level mutations (`List`'s `[…] → []` collapse) as an
    # identical off-table call, differing only by the held-back duration value.
    @list_and_value [Mutare.Mutators.List | @value]

    test "an explicit options list still collapses to [] — identical to an off-table call" do
      # `[max_concurrency: 4]` with no timeout: the List collapse fires for the table call exactly
      # as it does for a plain `foo(...)`, so membership in the duration table changes nothing here.
      {_m, table} =
        value_triples(
          "def f(e, fun), do: Task.async_stream(e, fun, [max_concurrency: 4])",
          @list_and_value
        )

      {_m, plain} =
        value_triples("def f(e, fun), do: foo(e, fun, [max_concurrency: 4])", @list_and_value)

      assert {:list, "[max_concurrency: 4]", "[]"} in table
      assert Enum.sort(table) == Enum.sort(plain)
    end

    test "with a timeout present, only the timeout value goes — the [] collapse stays" do
      {meta, ts} =
        value_triples(
          "def f(e, fun), do: Task.async_stream(e, fun, [timeout: 5000, max_concurrency: 4])",
          @list_and_value
        )

      # The duration value is held back…
      refute Enum.any?(ts, fn {m, o, _} -> m == :integer and o == "5000" end)

      # …but the list-level collapse (a `List`-family mutation, orthogonal to durations) survives,
      # showing the whole original options list including the timeout.
      assert {:list, "[timeout: 5000, max_concurrency: 4]", "[]"} in ts
      assert {:integer, "4", "3"} in ts
      assert_compiles(meta)
    end

    test "keyword sugar gets no [] collapse (as always) — the timeout value is still suppressed" do
      # Bare keyword sugar is never offered to List (table call or not), so there is no `[]` here;
      # the only change from baseline is the held-back timeout value.
      {_m, ts} =
        value_triples(
          "def f(e, fun), do: Task.async_stream(e, fun, timeout: 5000, max_concurrency: 4)",
          @list_and_value
        )

      refute Enum.any?(ts, fn {m, o, _} -> m == :integer and o == "5000" end)
      refute Enum.any?(ts, fn {m, _o, _} -> m == :list end)
      assert {:integer, "4", "3"} in ts
    end
  end

  describe "resolution: aliased, imported, and shadowed forms" do
    test "an aliased duration call is recognised" do
      {meta, triples} =
        value_triples("""
        alias Task, as: T
        def f(t), do: T.await(t, :infinity)
        """)

      assert triples == []
      assert_compiles(meta)
    end

    test "a piped timeout is suppressed (the pipe shift is accounted for)" do
      # `t |> Task.await(:infinity)`: the task is the piped receiver (effective index 0), so the
      # timeout is effective index 1 = visible index 0 — the suppression tracks the shift.
      {meta, triples} = value_triples("def f(t), do: t |> Task.await(:infinity)")

      assert triples == []
      assert_compiles(meta)
    end

    test "a duration piped as the receiver (effective index 0) is suppressed" do
      # `1000 |> Process.sleep()`: the duration *is* the piped value — the call's effective argument
      # 0, not one of its visible args. It is marked on the pipe's left side, so it is held back like
      # the plain `Process.sleep(1000)`; a computed value piped there still mutates its sub-literals.
      for body <- [
            "def f, do: 1000 |> Process.sleep()",
            "def f, do: 500 |> :timer.sleep()"
          ] do
        {meta, triples} = value_triples(body)
        assert triples == []
        assert_compiles(meta)
      end

      {_m, computed} = value_triples("def f(b), do: (b * 2) |> Process.sleep()")
      assert {:integer, "2", "1"} in computed

      # A non-timeout function piped the same way is untouched (the receiver pre-filter is exact).
      {_m, other} = value_triples("def f, do: 1000 |> Integer.to_string()")
      assert {:integer, "1000", "0"} in other
    end

    test "a shadowing alias resolves elsewhere and is NOT suppressed" do
      # `alias MyApp.Task, as: Task` rebinds `Task`, so `Task.await` resolves to `MyApp.Task` —
      # a different module the table does not list — and the literal timeout mutates normally.
      {_meta, triples} =
        value_triples("""
        alias MyApp.Task, as: Task
        def f(t), do: Task.await(t, 5000)
        """)

      assert {:integer, "5000", "0"} in triples
    end
  end

  describe "receive/after (already covered by pattern-position treatment)" do
    test "a receive's after-timeout literal is not mutated" do
      # The `after N -> …` timeout sits in the `->` clause's *pattern* position, which the walk
      # never offers — so a literal there is already inert, no duration table entry needed.
      {meta, triples} =
        value_triples("""
        def f do
          receive do
            msg -> msg
          after
            5000 -> :timeout
          end
        end
        """)

      refute Enum.any?(triples, fn {_m, o, _} -> o == "5000" end)
      assert_compiles(meta)
    end
  end

  describe "the marking facility is general (not timeout-specific)" do
    test "a custom mutator's declared position is marked, and it declines there" do
      # `MarkingMutator` marks `Widget.render/2`'s arg 1 — a function core knows nothing about — so
      # it skips the `2` while still mutating the unmarked `1` at arg 0.
      {_m, triples} = value_triples("def f, do: Widget.render(1, 2)", [MarkingMutator])

      assert {:marking, "1", "2"} in triples
      refute Enum.any?(triples, fn {_m, original, _} -> original == "2" end)
    end

    test "a mark is opt-in per label — a mutator that didn't request it still fires there" do
      # `IntegerLiteral` reacts to `:timeout`, not `:pinned`, so it mutates the `:pinned`-marked node
      # normally; only `MarkingMutator` declines it. Marks are a label a mutator opts into, not a
      # blanket suppression of the position.
      {_m, triples} =
        value_triples("def f, do: Widget.render(1, 2)", [
          MarkingMutator,
          Mutare.Mutators.IntegerLiteral
        ])

      assert {:integer, "2", "3"} in triples
      assert {:marking, "1", "2"} in triples
      refute {:marking, "2", "3"} in triples
    end

    test "a custom keyword-option mark works too" do
      # `Widget.stream/2`'s `:mode` option value is marked, so its literal is declined.
      {_m, triples} = value_triples("def f(e), do: Widget.stream(e, mode: 1)", [MarkingMutator])

      refute Enum.any?(triples, fn {m, original, _} -> m == :marking and original == "1" end)
    end
  end

  describe "configured marks (the `argument_marks:` option)" do
    # A user extends the same tables the mutators declare, in the same declaration shape
    # (`{module, function, arity, positions, label}`), and borrows the reading family's reaction:
    # under `:timeout`, `IntegerLiteral` declines every integer and `AtomLiteral` only `:infinity`,
    # while every other family proceeds. (To hold a position back from *every* family whatever its
    # value, route it `:raw` in `call_routes:` — see `transform_call_skip_test.exs`.)
    @int [Mutare.Mutators.IntegerLiteral]

    test "a configured :timeout position leaves the integer alone; unconfigured mutates it" do
      body = "def f(c), do: MyApp.Cache.put(c, :k, 300)"
      marks = [{MyApp.Cache, :put, 3, [2], :timeout}]

      {meta, configured} = value_triples(body, @int, argument_marks: marks)
      assert configured == []
      assert_compiles(meta)

      {_m, plain} = value_triples(body, @int)
      assert {:integer, "300", "0"} in plain
    end

    test "the reaction is the reading family's — value-aware, not a blanket pin" do
      # `:infinity` at a configured `:timeout` position is held back and a sibling atom is not; a
      # string there is not a duration at all, so `StringLiteral` (which reads no `:timeout`) fires.
      marks = [{MyApp.Cache, :put, 3, [2], :timeout}]

      {_m, atoms} =
        value_triples(
          "def f(c), do: MyApp.Cache.put(c, :normal, :infinity)",
          [Mutare.Mutators.AtomLiteral],
          argument_marks: marks
        )

      assert atoms == [{:atom, ":normal", ":mutare"}]

      {_m, strings} =
        value_triples(
          ~S|def f(c), do: MyApp.Cache.put(c, :k, "x")|,
          [Mutare.Mutators.StringLiteral],
          argument_marks: marks
        )

      assert {:string, ~S("x"), ~S("")} in strings
    end

    test "a mark is honored inside a `when` guard, not only in a body call" do
      # The guard/pattern tagging path (`Mutare.Transform.Tag`) offers a node to the mutators on its
      # own — separately from the in-place body offer — so it must surface the same position marks a
      # body offer does. `is_integer/1` is guard-safe, so `is_integer(123)` sits in guard position;
      # a configured mark on its argument must hold the literal back *there* just as it does in a
      # body call. Both the def-clause guard (lifted via `FunctionPlan`) and the `case`-clause guard
      # (via `Analyze`) route through `Tag.guard_targets`, so both are covered.
      marks = [{Kernel, :is_integer, 1, [0], :timeout}]

      for guarded <- [
            "def f(x) when is_integer(123), do: x",
            """
            def f(x) do
                case x do
                  y when is_integer(123) -> y
                end
              end\
            """
          ] do
        assert value_triples(guarded, @int, argument_marks: marks) |> elem(1) == [],
               "expected the guard literal held back in `#{guarded}`"
      end

      # Non-vacuous: unconfigured, the same guard literal mutates fully.
      {_m, plain} = value_triples("def f(x) when is_integer(123), do: x", @int)
      assert {:integer, "123", "0"} in plain
    end

    test "a configured keyword-option value is left alone" do
      {_m, triples} =
        value_triples("def f(r), do: MyApp.get(r, recv_timeout: 500)", @int,
          argument_marks: [{MyApp, :get, 2, [{:keyword, :recv_timeout}], :timeout}]
        )

      assert triples == []
    end

    test "a configured keyword-option mark covers the options list piped as the receiver" do
      # An arity-1 API whose only argument is options can be spelled with the list as the pipe
      # receiver — `[timeout: 500] |> MyApp.configure()`. The receiver is effective argument 0
      # *and* the trailing argument, so the `{:keyword, :timeout}` mark must reach the piped
      # option value just as in the written `MyApp.configure(timeout: 500)`.
      marks = [{MyApp, :configure, 1, [{:keyword, :timeout}], :timeout}]

      assert value_triples("def f, do: MyApp.configure(timeout: 500)", @int,
               argument_marks: marks
             )
             |> elem(1) == []

      assert value_triples("def f, do: [timeout: 500] |> MyApp.configure()", @int,
               argument_marks: marks
             )
             |> elem(1) == []

      # Not vacuous: unconfigured, the piped option value mutates…
      {_m, plain} = value_triples("def f, do: [timeout: 500] |> MyApp.configure()", @int)
      assert {:integer, "500", "0"} in plain

      # …and under the config an unmarked sibling key still does — the mark froze one value, not
      # the list.
      {_m, sibling} =
        value_triples("def f, do: [pool: 5, timeout: 500] |> MyApp.configure()", @int,
          argument_marks: marks
        )

      assert {:integer, "5", "6"} in sibling or {:integer, "5", "0"} in sibling
      refute Enum.any?(sibling, fn {_m, original, _} -> original == "500" end)
    end

    test "a negative literal at a configured position is held back (mark reaches inside the unary -)" do
      # `-300` parses as `{:-, _, [300]}` and the value families fire on the inner positive literal,
      # so the mark must reach it — otherwise `MyApp.put(c, -300)` slips past a mark that catches
      # `MyApp.put(c, 300)`. Positional and keyword alike (this applies to the built-in table too,
      # since the fix is in the shared stamping).
      for {body, marks} <- [
            {"def f(c), do: MyApp.put(c, -300)", [{MyApp, :put, 2, [1], :timeout}]},
            {"def f(c), do: MyApp.put(c, timeout: -300)",
             [{MyApp, :put, 2, [{:keyword, :timeout}], :timeout}]}
          ] do
        {_m, triples} = value_triples(body, @int, argument_marks: marks)
        assert triples == [], "expected -literal held back in `#{body}`, got #{inspect(triples)}"
      end

      # A *computed* negative (`-(x + 1)`) is not a bare literal, so its sub-literal still mutates.
      {_m, computed} =
        value_triples("def f(c, x), do: MyApp.put(c, -(x + 1))", @int,
          argument_marks: [{MyApp, :put, 2, [1], :timeout}]
        )

      assert {:integer, "1", "0"} in computed
    end

    test "a custom mutator's label is configurable too, once that mutator is enabled" do
      # `MarkingMutator` declares `:pinned` positions of its own; a config entry under the same
      # label extends its table, and the mutator reacts to it exactly as to its own declaration.
      {_m, triples} =
        value_triples("def f, do: Widget.other(1, 2)", [MarkingMutator],
          argument_marks: [{Widget, :other, 2, [1], :pinned}]
        )

      assert {:marking, "1", "2"} in triples
      refute Enum.any?(triples, fn {_m, o, _} -> o == "2" end)
    end

    test "a label no configured mutator declares is rejected at startup" do
      assert_raise ArgumentError, ~r/no configured mutator declares positions for/, fn ->
        Mutare.Options.new(argument_marks: [{MyApp, :put, 2, [1], :nope}])
      end

      # A built-in label stays known even when the run is narrowed below its declaring family…
      assert %Mutare.Options{} =
               Mutare.Options.new(
                 mutators: [:arithmetic],
                 argument_marks: [{MyApp, :put, 2, [1], :timeout}]
               )

      # …and a custom mutator's label is known once that mutator is configured.
      assert %Mutare.Options{} =
               Mutare.Options.new(
                 mutators: [MarkingMutator],
                 argument_marks: [{Widget, :other, 2, [1], :pinned}]
               )
    end

    test "a malformed entry fails loudly" do
      assert_raise ArgumentError, ~r/invalid argument-mark entry/, fn ->
        value_triples("def f, do: 1", @int, argument_marks: [{MyApp, :put, "bad", [1], :timeout}])
      end

      assert_raise ArgumentError,
                   ~r/expected \{module, function, arity, positions, label\}/,
                   fn ->
                     Mutare.Options.new(argument_marks: [{MyApp, :put, 2, [1]}])
                   end
    end

    test "a one-based (out-of-range) index is rejected, not silently ignored" do
      # Effective indices for arity 3 are 0..2; `[3]` is a one-based typo that would mark nothing.
      assert_raise ArgumentError, ~r/below the arity 3/, fn ->
        value_triples("def f, do: 1", @int, argument_marks: [{MyApp, :put, 3, [3], :timeout}])
      end
    end

    test "a configured effective-index-0 mark covers both the plain and piped receiver forms" do
      # `Kernel.to_string/1` arg 0 is the value in `to_string(123)` and the piped receiver in
      # `123 |> to_string()`. Both are held back — the piped receiver resolves through the same
      # Kernel/import machinery as the written call. The *parenless* pipe `123 |> to_string` counts
      # too: Sourceror gives its RHS `nil` (not `[]`) args, a shape that is a variable outside pipe
      # position but always a 0-arg call as a pipe RHS.
      marks = [{Kernel, :to_string, 1, [0], :timeout}]

      assert value_triples("def f, do: to_string(123)", @int, argument_marks: marks) |> elem(1) ==
               []

      assert value_triples("def f, do: 123 |> to_string()", @int, argument_marks: marks)
             |> elem(1) == []

      assert value_triples("def f, do: 123 |> to_string", @int, argument_marks: marks) |> elem(1) ==
               []

      # …while an unconfigured Kernel call is untouched, in every spelling.
      assert {:integer, "123", "0"} in (value_triples("def f, do: to_string(123)", @int)
                                        |> elem(1))

      assert {:integer, "123", "0"} in (value_triples("def f, do: 123 |> to_string", @int)
                                        |> elem(1))
    end

    test "an imported, parenless piped receiver mark applies (the RHS import is resolved)" do
      # A bare-name pipe RHS written without parens (`1000 |> sleep`) has `nil` args and the generic
      # resolve walk leaves it unstamped, so the receiver path must resolve the RHS import itself.
      # `import Process; 1000 |> sleep` is the built-in timeout table via an imported bare name…
      assert value_triples("import Process\n  def f, do: 1000 |> sleep") |> elem(1) == []

      # …and a configured mark on an imported function honours the same parenless form, while the
      # unconfigured call still mutates the receiver (not a vacuous check).
      body = "import Integer\n  def f, do: 123 |> to_string"
      marks = [{Integer, :to_string, 1, [0], :timeout}]

      assert value_triples(body, @int, argument_marks: marks) |> elem(1) == []
      assert {:integer, "123", "0"} in (value_triples(body, @int) |> elem(1))
    end

    test "a configured mark reaches a bare call through a whole import of a project module" do
      # `import MyApp.Cache` can't be resolved by reflection (the module lives only in the target
      # project, never loadable here), so `Imports.stamp` leaves the bare `put/3` unstamped — but
      # the mark declaration itself asserts `MyApp.Cache.put/3` exists, and the compile-unambiguity
      # rule makes the bare call under the whole import unambiguously it. The resolver's
      # marks-registry fallback (`marked_import_module/3`, the twin of the route-registry fallback)
      # must therefore apply the mark to the imported bare form just as to the remote and
      # selective-import forms.
      marks = [{MyApp.Cache, :put, 3, [2], :timeout}]
      body = "import MyApp.Cache\n  def f(c), do: put(c, :k, 300)"

      assert value_triples(body, @int, argument_marks: marks) |> elem(1) == []

      # …including the pipe-shifted form (the piped receiver is effective arg 0, so the marked
      # effective index 2 is visible index 1)…
      piped = "import MyApp.Cache\n  def f(c), do: c |> put(:k, 300)"
      assert value_triples(piped, @int, argument_marks: marks) |> elem(1) == []

      # …and the piped-receiver path (`pipe_target/2` resolves the RHS through the same fallback),
      # parens or parenless.
      recv = [{MyApp.Cache, :sleepish, 1, [0], :timeout}]

      assert value_triples("import MyApp.Cache\n  def f, do: 300 |> sleepish()", @int,
               argument_marks: recv
             )
             |> elem(1) == []

      assert value_triples("import MyApp.Cache\n  def f, do: 300 |> sleepish", @int,
               argument_marks: recv
             )
             |> elem(1) == []

      # Not vacuous, and exactly keyed: unconfigured mutates, and the fallback is per-arity — a
      # 2-ary `put` matches no `{…, :put, 3, …}` declaration, so its literal mutates normally.
      assert {:integer, "300", "0"} in (value_triples(body, @int) |> elem(1))

      assert {:integer, "300", "0"} in (value_triples(
                                          "import MyApp.Cache\n  def f(c), do: put(c, 300)",
                                          @int,
                                          argument_marks: marks
                                        )
                                        |> elem(1))
    end
  end

  defp value_triples(body, mutators \\ @value, opts \\ []) do
    source = "defmodule M do\n  #{String.trim_trailing(body)}\nend\n"

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(source, [mutators: mutators] ++ opts)

    {meta, for(s <- sites, do: {s.mutator, s.original_code, s.mutated_code})}
  end
end
