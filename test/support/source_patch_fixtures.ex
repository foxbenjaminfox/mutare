defmodule Mutare.Test.SourcePatchFixtures do
  @moduledoc """
  Effect-and-scope vocabulary for generated source-patch comparisons.

  `observe/1` returns both an outcome and an ordered trace, including effects before a
  raise/throw/exit. The trace lives only for that observation and is restored in `after`.
  These helpers live outside the transformed source: instrumentation cannot mutate the
  observer itself. Generated functions return their escaping bindings beside their result.

  `identity/1`, `raw/1`, `lazy/2`, and the keyword routes in `SourcePatchGenerators` let the same
  expressions cross different routing boundaries. No clocks, processes, or random runtime
  state are involved. Callers selecting mutants must still run `async: false`.
  """
  @trace_key {__MODULE__, :trace}

  def observe(fun) do
    previous = Process.get(@trace_key, :absent)
    Process.put(@trace_key, [])

    try do
      outcome =
        try do
          {:returned, fun.()}
        rescue
          exception -> {:raised, exception.__struct__}
        catch
          kind, reason -> {kind, reason}
        end

      {outcome, Enum.reverse(Process.get(@trace_key))}
    after
      case previous do
        :absent -> Process.delete(@trace_key)
        trace -> Process.put(@trace_key, trace)
      end
    end
  end

  def tick(value, label) do
    Process.put(@trace_key, [label | Process.get(@trace_key)])
    value
  end

  def receiver, do: tick(:erlang, :receiver)
  def identity(value), do: value
  defmacro raw(_syntax), do: 7

  defmacro lazy(value, enabled) do
    quote do
      if unquote(enabled), do: unquote(value), else: 0
    end
  end
end

defmodule Mutare.Test.SourcePatchDynamicMutator do
  @moduledoc """
  Supply retained- and moved-operand candidates on a dynamic `div/2` call, which the
  built-in arithmetic families correctly cannot identify as an Erlang call. Both variants
  retain every argument expression, so even binding-bearing source patches still compile.
  """
  @behaviour Mutare.Mutator

  @impl true
  def name, do: :dynamic_arithmetic

  @impl true
  def mutate({{:., dot_meta, [receiver, :div]}, meta, [left, right]}, %{opts: opts}) do
    retained = {{:., dot_meta, [receiver, :rem]}, meta, [left, right]}
    moved = {{:., dot_meta, [receiver, :div]}, meta, [right, left]}

    case Keyword.fetch!(opts, :delivery) do
      :retained -> [retained]
      :moved -> [moved]
      :split -> [retained, moved]
    end
  end

  def mutate(_node, _context), do: :skip
end

defmodule Mutare.Test.SourcePatchKeywordRoutes do
  @moduledoc false
  @behaviour Mutare.CallRouting

  @impl true
  def call_routes, do: [{Keyword, :get, 2, [{:keyword, [:expression]}, :expression]}]
end
