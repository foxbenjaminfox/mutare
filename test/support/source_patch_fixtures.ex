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

  # A binding macro (`destructure/2`'s shape) with no built-in declaration: the
  # `:declaration_shadowed` operand declares it at any arity and skips the exact one.
  defmacro unpack(pattern, value) do
    quote do
      unquote(pattern) = unquote(value)
    end
  end

  defmacro lazy(value, enabled) do
    quote do
      if unquote(enabled), do: unquote(value), else: 0
    end
  end

  # The least convenient valid readings of two routing words. `:lazy_expression` promises
  # only that the macro decides when its argument runs: this one runs it twice.
  defmacro twice(value) do
    quote do
      unquote(value)
      unquote(value)
    end
  end

  # `:interior` promises only that the root call is the macro's to read: this one takes the
  # call apart and evaluates its second argument first.
  defmacro reversed({name, meta, [first, second]}) do
    quote do
      second = unquote(second)
      first = unquote(first)
      unquote({name, meta, [quote(do: first), quote(do: second)]})
    end
  end
end

defmodule Mutare.Test.SourcePatchDynamicMutator do
  @moduledoc """
  Supply retained-, moved- and dropped-operand candidates on a dynamic `div/2` call, which
  the built-in arithmetic families correctly cannot identify as an Erlang call. The first two
  retain every argument expression; `:dropped` (`receiver.abs(left)`) removes the second
  argument, and the binding of `right` it made — a name the fixture binds before the
  expression, so the patch still compiles and reads the incoming value.
  """
  @behaviour Mutare.Mutator

  @impl true
  def name, do: :dynamic_arithmetic

  @impl true
  def mutate({{:., dot_meta, [receiver, :div]}, meta, [left, right]}, %{opts: opts}) do
    retained = {{:., dot_meta, [receiver, :rem]}, meta, [left, right]}
    moved = {{:., dot_meta, [receiver, :div]}, meta, [right, left]}
    dropped = {{:., dot_meta, [receiver, :abs]}, meta, [left]}

    case Keyword.fetch!(opts, :delivery) do
      :retained -> [retained]
      :moved -> [moved]
      :split -> [retained, moved]
      :dropped -> [dropped]
    end
  end

  def mutate(_node, _context), do: :skip
end

defmodule Mutare.Test.SourcePatchDropMutator do
  @moduledoc """
  `div(left, right)` → `abs(left)`: the static twin of the dynamic mutator's `:dropped`
  delivery. The second argument goes, and with it the `right` binding it made.
  """
  @behaviour Mutare.Mutator

  @impl true
  def name, do: :drop_argument

  # A bare `div/2` is Kernel's by arity, as the built-in families read it; the recipes write
  # no other.
  @impl true
  def mutate({:div, meta, [left, _right]}), do: [{:abs, meta, [left]}]

  def mutate(node) do
    case Mutare.Calls.resolved_call_to(node, Kernel, :div) do
      {:ok, :div, [left, _right], rebuild} -> [rebuild.(:abs, [left])]
      _other -> []
    end
  end
end

defmodule Mutare.Test.SourcePatchUnwrapMutator do
  @moduledoc """
  Replace a negated statement sequence, `-(a; b)`, with the sequence. The replacement is
  patched over the whole negation, so the parentheses, which group the operator's operand,
  go with it: the Site's text has to restore them, or the patch splices two statements into
  an argument list.
  """
  @behaviour Mutare.Mutator

  @impl true
  def name, do: :unwrap

  @impl true
  def mutate({:-, _meta, [{:__block__, _, [_, _ | _]} = sequence]}), do: [sequence]
  def mutate(_node), do: :skip
end

defmodule Mutare.Test.SourcePatchUnpackRoutes do
  @moduledoc false
  @behaviour Mutare.CallRouting

  @impl true
  def call_routes,
    do: [{Mutare.Test.SourcePatchFixtures, :unpack, :any, [:binding_pattern, :expression]}]
end

defmodule Mutare.Test.SourcePatchKeywordRoutes do
  @moduledoc false
  @behaviour Mutare.CallRouting

  @impl true
  def call_routes, do: [{Keyword, :get, 2, [{:keyword, [:expression]}, :expression]}]
end
