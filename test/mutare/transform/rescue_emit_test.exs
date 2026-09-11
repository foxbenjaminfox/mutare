defmodule Mutare.Transform.RescueEmitTest do
  use ExUnit.Case, async: false
  import Mutare.Test.Metamutant

  alias Mutare.Coverage.Recorder
  alias Mutare.{Manifest, Selector, Transform}

  defmodule WholeTry do
    @behaviour Mutare.Mutator
    def name, do: :whole_try
    def mutate({:try, _, _}), do: [Mutare.AST.literal(:replaced)]
    def mutate(_), do: :skip
  end

  defmodule CoverageSink do
    def hit(ids) do
      send(Process.get(:rescue_observer), {:covered, ids})
      true
    end
  end

  defmodule StageSwap do
    @behaviour Mutare.Mutator
    def name, do: :stage_swap
    def mutate({:stage, _, []}), do: [quote(do: List.wrap())]
    def mutate(_), do: :skip
  end

  setup do
    track = :persistent_term.get(Recorder.track_key(), false)
    Selector.put(0)
    :persistent_term.put(Recorder.track_key(), false)

    on_exit(fn ->
      Selector.put(0)
      :persistent_term.put(Recorder.track_key(), track)
    end)

    :ok
  end

  test "a variable named try retains ordinary return-value selection with default mutators" do
    {module, sites, _, _, _var} =
      fixture("TryVariable", "def run(try), do: try", Mutare.Mutators.all())

    assert Enum.map(sites, &{&1.mutator, &1.mutated_code}) ==
             [{:return_value, "nil"}, {:return_value, ":mutare"}]

    assert outcome(module, [:original]) == {{:returned, :original}, []}

    for {site, expected} <- Enum.zip(sites, [nil, :mutare]) do
      Selector.put(site.id)
      assert outcome(module, [:original]) == {{:returned, expected}, []}
    end
  end

  test "other-arity calls named try retain ordinary return-value selection" do
    for body <- [
          "def run(_), do: try()\ndefp try(), do: :ok",
          "def run(value), do: try(value, value)\ndefp try(_, _), do: :ok"
        ] do
      {module, sites, _, _, _var} = fixture("TryCall", body, Mutare.Mutators.all())

      assert Enum.map(sites, &{&1.mutator, &1.mutated_code}) ==
               [{:return_value, "nil"}, {:return_value, ":mutare"}]

      Selector.put(0)
      assert outcome(module, [:original]) == {{:returned, :ok}, []}

      for {site, expected} <- Enum.zip(sites, [nil, :mutare]) do
        Selector.put(site.id)
        assert outcome(module, [:original]) == {{:returned, expected}, []}
      end
    end
  end

  test "large protected bodies and cleanup have at most two copies as rescue types grow" do
    types =
      ~w(ArgumentError RuntimeError ArithmeticError KeyError MatchError CaseClauseError FunctionClauseError Protocol.UndefinedError)

    for count <- [2, 8] do
      {module, sites, meta, _, _var} =
        fixture("Growth", """
        def run(x) do
          try do
            #{inspect(__MODULE__)}.event(:do)
            #{Enum.join(List.duplicate("x = x + 2", 160), "\n")}
            x
          rescue
            e in [#{Enum.join(Enum.take(types, count), ", ")}] -> e.__struct__
          after
            #{inspect(__MODULE__)}.event(:after)
          end
        end
        """)

      assert length(sites) == count
      assert event_count(meta, :do) in 1..2
      assert event_count(meta, :after) in 1..2

      for id <- [0 | Enum.map(sites, & &1.id)] do
        Selector.put(id)
        assert outcome(module, [20]) == {{:returned, 340}, [:do, :after]}
      end
    end
  end

  test "rescue mutants preserve direct and reraised stack frames" do
    {module, sites, _, _, _var} =
      fixture("Stack", """
      def run(x, reraising) do
        try do
          div(10, x)
        rescue
          e in [ArithmeticError, RuntimeError] ->
            if reraising, do: reraise(e, __STACKTRACE__)
            {e.__struct__, #{inspect(__MODULE__)}.frames(__STACKTRACE__, __MODULE__)}
        after
          #{inspect(__MODULE__)}.event(:after)
        end
      end
      """)

    catches = Enum.find(sites, &(&1.mutated_code == "e in [ArithmeticError]"))
    propagates = Enum.find(sites, &(&1.mutated_code == "e in [RuntimeError]"))

    for id <- [0, catches.id] do
      Selector.put(id)

      assert outcome(module, [0, false]) ==
               {{:returned, {ArithmeticError, [run: 2]}}, [:after]}

      assert {{:raised, :error, %ArithmeticError{}, [run: 2]}, [:after]} =
               outcome(module, [0, true])
    end

    Selector.put(propagates.id)
    assert outcome(module, [0, false]) == {{:raised, :error, :badarith, [run: 2]}, [:after]}
  end

  test "source macros see no new bindings in do, rescue, else, or after" do
    {module, sites, meta, _, _var} =
      fixture("Scope", """
      defmacro scope, do: Macro.escape(Macro.Env.vars(__CALLER__))
      def run(failure) do
        try do
          #{inspect(__MODULE__)}.event({:do, scope()})
          if failure, do: raise(failure)
          :ok
        rescue
          e in [ArgumentError, RuntimeError] -> {e.__struct__, scope()}
        else
          :ok -> {:success, scope()}
        after
          #{inspect(__MODULE__)}.event({:after, scope()})
        end
      end
      """)

    # A single protected body proves these assertions exercise factoring.
    assert String.split(meta, "if failure") |> length() == 2
    outer = [failure: nil, mutare_active: nil]
    handler = [e: nil, failure: nil, mutare_active: nil]

    for id <- [0 | Enum.map(sites, & &1.id)] do
      Selector.put(id)

      assert outcome(module, [nil]) ==
               {{:returned, {:success, outer}}, [do: outer, after: outer]}
    end

    for site <- sites do
      Selector.put(site.id)
      type = if site.mutated_code == "e in [ArgumentError]", do: ArgumentError, else: RuntimeError

      assert outcome(module, [type]) ==
               {{:returned, {type, handler}}, [do: outer, after: outer]}
    end
  end

  test "rescue mutants retain raw macro scope inside do, else, and after pipes" do
    {module, sites, _, _, _var} =
      fixture(
        "RawScope",
        """
        defmacro stage(value) do
          vars = Macro.escape(Macro.Env.vars(__CALLER__))
          quote do: {unquote(value), unquote(vars)}
        end
        def run(x) do
          try do
            x |> stage()
          rescue
            e in [ArgumentError, RuntimeError] -> e.__struct__
          else
            value -> value |> stage()
          after
            #{inspect(__MODULE__)}.event(x |> stage())
          end
        end
        """,
        [StageSwap, :rescue_type]
      )

    assert Enum.count(sites, &(&1.mutator == :stage_swap)) == 3
    assert {{:returned, {{3, do_vars}, else_vars}}, [{3, after_vars}]} = outcome(module, [3])
    assert Keyword.has_key?(do_vars, :mutare_piped)
    assert Keyword.has_key?(else_vars, :mutare_piped)
    assert Keyword.has_key?(after_vars, :mutare_piped)

    for site <- Enum.filter(sites, &(&1.mutator == :rescue_type)) do
      Selector.put(site.id)
      outer = [mutare_active: nil, x: nil]
      inner = [mutare_active: nil, value: nil, x: nil]
      assert outcome(module, [3]) == {{:returned, {{3, outer}, inner}}, [{3, outer}]}
    end
  end

  for form <- [:explicit, :implicit], catches? <- [false, true] do
    test "#{form} rescue, catch=#{catches?}: every mutant matches a source patch across failure boundaries" do
      blocks = boundary_blocks(unquote(catches?))
      body = if unquote(form) == :explicit, do: "do\ntry #{blocks}\nend", else: blocks

      {module, sites, _, source, _var} =
        fixture("Boundary", "def run(action, handler, cleanup) #{body}")

      args =
        for action <- [
              :ok,
              :else_raise,
              :unmatched_else,
              :badarith,
              :badarg,
              :throw,
              :exit,
              :error,
              ArgumentError,
              RuntimeError
            ],
            handler <- [:return, :raise, :throw, :exit, :reraise],
            cleanup <- [:ok, :raise, :throw, :exit],
            do: [action, handler, cleanup]

      assert Enum.count(sites, &(&1.operation == :replace)) == 2
      assert Enum.count(sites, &(&1.operation == :delete)) == 2
      assert_source_patches(module, source, sites, args)
    end
  end

  test "default body and handler mutants still match their individual source patches" do
    {module, sites, _, source, _var} =
      fixture(
        "Defaults",
        """
        def run(x, failure) do
          try do
            if failure, do: raise(failure)
            x + 2
          rescue
            e in [ArgumentError, RuntimeError] -> {:rescued, e.__struct__}
          after
            #{inspect(__MODULE__)}.event(:after)
          end
        end
        """,
        Mutare.Mutators.all()
      )

    assert Enum.any?(sites, &(&1.mutator == :rescue_type))
    assert Enum.any?(sites, &(&1.mutator == :arithmetic))

    args =
      for x <- [0, 3], failure <- [nil, ArgumentError, RuntimeError, KeyError], do: [x, failure]

    assert_source_patches(module, source, sites, args)
  end

  test "coverage records all live rescue ids before successful or raising body evaluation" do
    {module, sites, meta, _, _var} = fixture("Coverage", simple_body())

    observed =
      String.replace(
        meta,
        "#{inspect(Recorder.fixture_module())}.hit(",
        "#{inspect(CoverageSink)}.hit("
      )

    compile_purging(module, observed)
    Process.put(:rescue_observer, self())
    :persistent_term.put(Recorder.track_key(), true)
    ids = Enum.map(sites, & &1.id)

    for action <- [fn -> :success end, fn -> raise ArgumentError end] do
      outcome(module, [action])
      assert_received {:covered, ^ids}
      refute_received {:covered, _}
    end
  end

  test "selection stays fixed when the protected body changes persistent_term" do
    {module, sites, _, _, _var} = fixture("Snapshot", simple_body())
    catches = Enum.find(sites, &(&1.mutated_code == "e in [ArgumentError]"))
    propagates = Enum.find(sites, &(&1.mutated_code == "e in [RuntimeError]"))
    Selector.put(catches.id)

    action = fn ->
      Selector.put(propagates.id)
      raise ArgumentError
    end

    assert outcome(module, [action]) == {{:returned, ArgumentError}, [:do, :after]}
  end

  test "whole-node mutants bypass the body, while skips preserve ids and manifest ownership" do
    {module, sites, meta, source, var} =
      fixture("Selection", simple_body(), [WholeTry, :rescue_type])

    [whole | rescues] = sites
    assert whole.mutator == :whole_try
    Selector.put(whole.id)
    assert outcome(module, [fn -> raise "not reached" end]) == {{:returned, :replaced}, []}

    manifest = Manifest.from_source(meta, var)

    for site <- rescues do
      line =
        meta |> String.split("\n") |> Enum.find_index(&String.contains?(&1, site.mutated_code))

      assert line
      assert Manifest.ids_at_line(manifest, line + 1) == [site.id]
    end

    %{metamutant: skipped, sites: skipped_sites, next_id: next_id} =
      Transform.transform_string_with_sites(source,
        mutators: [WholeTry, :rescue_type],
        skip_ids: Enum.map(rescues, & &1.id)
      )

    assert Enum.map(skipped_sites, & &1.id) == Enum.map(sites, & &1.id)
    assert next_id == List.last(sites).id + 1
    refute String.contains?(skipped, ":erlang.raise(")
  end

  test "bare, mixed, and underscored rescue bindings retain whole-try delivery" do
    for heads <- [
          "[ArgumentError, RuntimeError] -> :caught",
          "e in ArgumentError -> e; other in RuntimeError -> other",
          "_e in [ArgumentError, RuntimeError] -> :caught"
        ] do
      {module, sites, meta, _, _var} =
        fixture("Fallback", """
        def run(action) do
          try do
            #{inspect(__MODULE__)}.event(:do)
            action.()
          rescue
            #{heads}
          end
        end
        """)

      assert event_count(meta, :do) == length(sites) + 1
      assert outcome(module, [fn -> :success end]) == {{:returned, :success}, [:do]}
    end
  end

  test "an unbound enclosing rescue retains the original macro scope of mutant branches" do
    {module, sites, meta, _, _var} =
      fixture("Unbound", """
      defmacro scope, do: Macro.escape(Macro.Env.vars(__CALLER__))
      def run(action) do
        raise "outer rescue"
      rescue
        _ ->
          try do
            #{inspect(__MODULE__)}.event(:do)
            action.()
          rescue
            e in [ArgumentError, RuntimeError] -> {e.__struct__, scope()}
          end
      end
      """)

    assert event_count(meta, :do) == 3
    catches = Enum.find(sites, &(&1.mutated_code == "e in [ArgumentError]"))
    Selector.put(catches.id)

    assert outcome(module, [fn -> raise ArgumentError end]) ==
             {{:returned, {ArgumentError, [action: nil, e: nil]}}, [:do]}
  end

  test "a catch-all rescue with the shared binding preserves narrowing and clause fallthrough" do
    {module, sites, meta, source, _var} =
      fixture("CatchAll", """
      def run(action) do
        try do
          #{inspect(__MODULE__)}.event(:do)
          action.()
        rescue
          e in [ArgumentError, RuntimeError] -> {:listed, e.__struct__}
          e -> {:other, e.__struct__}
        after
          #{inspect(__MODULE__)}.event(:after)
        end
      end
      """)

    assert event_count(meta, :do) in 1..2

    inputs = [
      [fn -> :success end],
      [fn -> raise ArgumentError end],
      [fn -> raise RuntimeError end],
      [fn -> :erlang.error(:unlisted) end]
    ]

    assert_source_patches(module, source, sites, inputs)
  end

  def event(value) do
    Process.put(:rescue_events, [value | Process.get(:rescue_events, [])])
    value
  end

  def frames(stack, module),
    do: for({m, f, a, _} <- stack, m == module, do: {f, a})

  defp outcome(module, args) do
    Process.put(:rescue_events, [])

    result =
      try do
        {:returned, apply(module, :run, args)}
      catch
        kind, reason -> {:raised, kind, reason, frames(__STACKTRACE__, module)}
      end

    {result, Enum.reverse(Process.get(:rescue_events))}
  end

  defp assert_source_patches(module, source, sites, inputs) do
    for site <- [nil | sites] do
      reference = fresh_module("Reference")

      patched =
        if site do
          change = if site.operation == :delete, do: "", else: site.mutated_code
          Sourceror.patch_string(source, [%{range: site.range, change: change}])
        else
          source
        end

      patched =
        String.replace(patched, "defmodule #{inspect(module)}", "defmodule #{inspect(reference)}",
          global: false
        )

      compile_purging(reference, patched)
      Selector.put(if site, do: site.id, else: 0)

      for args <- inputs do
        assert outcome(module, args) == outcome(reference, args),
               "mutant #{inspect(site && site.id)}, input #{inspect(args)}"
      end
    end
  end

  defp fresh_module(name),
    do: Module.concat(__MODULE__, "#{name}#{System.unique_integer([:positive])}")

  defp fixture(name, body, mutators \\ [:rescue_type]) do
    module = fresh_module(name)
    source = "defmodule #{inspect(module)} do\n#{body}\nend"

    %{metamutant: meta, sites: sites, dispatch_var: var} =
      Transform.transform_string_with_sites(source, mutators: mutators)

    compile_purging(module, meta)
    {module, sites, meta, source, var}
  end

  defp event_count(source, value) do
    {_, count} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(0, fn
        {{:., _, [_, :event]}, _, [^value]} = node, count -> {node, count + 1}
        node, count -> {node, count}
      end)

    count
  end

  defp simple_body do
    """
    def run(action) do
      try do
        #{inspect(__MODULE__)}.event(:do)
        action.()
      rescue
        e in [ArgumentError, RuntimeError] -> e.__struct__
      after
        #{inspect(__MODULE__)}.event(:after)
      end
    end
    """
  end

  defp boundary_blocks(catches?) do
    catch_block =
      if catches?,
        do:
          "catch\nkind, reason -> #{inspect(__MODULE__)}.event({:catch, kind, reason}); {:caught, kind, reason}",
        else: ""

    """
    do
      #{inspect(__MODULE__)}.event(:do)
      case action do
        :ok -> 10
        :else_raise -> :else_raise
        :unmatched_else -> :unmatched_else
        :badarith -> div(10, 0)
        :badarg -> :erlang.error(:badarg)
        :throw -> throw(:thrown)
        :exit -> exit(:exited)
        :error -> :erlang.error(:unlisted)
        _ -> raise(action)
      end
    rescue
      e in [ArgumentError, ArithmeticError] ->
        #{inspect(__MODULE__)}.event({:rescue, e.__struct__})
        case handler do
          :return -> {:rescued, e.__struct__}
          :raise -> raise RuntimeError
          :throw -> throw(:handler_throw)
          :exit -> exit(:handler_exit)
          :reraise -> reraise e, __STACKTRACE__
        end
      e in RuntimeError -> #{inspect(__MODULE__)}.event({:runtime, e.__struct__})
    #{catch_block}
    else
      10 -> #{inspect(__MODULE__)}.event(:else); :success
      :else_raise -> raise ArgumentError
    after
      #{inspect(__MODULE__)}.event(:after)
      case cleanup do
        :ok -> :ok
        :raise -> raise KeyError
        :throw -> throw(:cleanup_throw)
        :exit -> exit(:cleanup_exit)
      end
    end
    """
  end
end
