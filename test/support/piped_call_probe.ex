defmodule Mutare.Test.PipedCallDSL do
  @moduledoc """
  A fake query DSL with one composable macro, `stage/2`, whose first argument may be something
  that is *not* an Elixir value — the analog of Ecto's `from`, which accepts a schema alias or a
  binding declaration (`p in Post`) where a function would need an expression. Written piped,
  that argument is the `|>`'s left side.
  """

  @doc "Thread `source` through, keeping it only when `condition` holds."
  defmacro stage({:in, _meta, [binding, source]}, condition) do
    quote do
      unquote(binding) = unquote(source)
      if unquote(condition), do: unquote(binding), else: []
    end
  end

  defmacro stage(source, condition) do
    quote do
      if unquote(condition), do: unquote(source), else: []
    end
  end
end

defmodule Mutare.Test.PipedCallProbe do
  @moduledoc """
  Reports the `Mutare.CallRouting.Call` each of an adapter's three seams is shown for a
  `Mutare.Test.PipedCallDSL.stage/2` call — `c:Mutare.CallRouting.route_arguments/2`,
  `c:Mutare.Mutator.MacroHost.host/2`, and `Mutare.Calls.resolved_routed_call/1` from inside
  `c:Mutare.Mutator.mutate/2` — by sending `{:piped_call_probe, seam, call}` to the process
  running the transform.

  Its classifier routes the source **by its shape**, which a piped source shares with a written
  one: a schema alias or a binding declaration is left `:raw` (an alias swap there is a broken
  query, not a mutant), and anything else is a `:lazy_expression`, so the upstream code keeps
  its mutants.

  Its one mutation rewrites argument 0 — a binding declaration's source, `p in xs` to
  `p in Enum.reverse(xs)` — the analog of an adapter reordering a piped query's bindings.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.CallRouting
  @behaviour Mutare.Mutator.MacroHost

  alias Mutare.CallRouting.{ArgumentRoutes, Call}

  @dsl Mutare.Test.PipedCallDSL

  @impl Mutare.Mutator
  def name, do: :piped_call_probe

  @impl Mutare.CallRouting
  def call_routes, do: [{@dsl, :stage, 2, :routing}]

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{@dsl, :stage, 2}]

  @impl Mutare.CallRouting
  def route_arguments(%Call{arguments: [source, _condition]} = call, _context) do
    report(:route_arguments, call)
    ArgumentRoutes.new(call, [source_treatment(source), :hosted])
  end

  @impl Mutare.Mutator.MacroHost
  def host(%Call{} = call, _context) do
    report(:host, call)
    []
  end

  @impl Mutare.Mutator
  def mutate(node, _context) do
    case Mutare.Calls.resolved_routed_call(node) do
      %Call{module: @dsl} = call ->
        report(:mutate, call)
        reversed_source(call)

      _other ->
        :skip
    end
  end

  defp reversed_source(%Call{
         name: name,
         arguments: [{:in, meta, [binding, source]} | rest],
         rebuild: rebuild
       }) do
    reversed = {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [source]}
    [rebuild.(name, [{:in, meta, [binding, reversed]} | rest])]
  end

  defp reversed_source(%Call{}), do: :skip

  defp source_treatment({:__aliases__, _meta, _segments}), do: :raw
  defp source_treatment({:in, _meta, [_binding, _queryable]}), do: :raw
  # `stage/2` evaluates its source only when the condition holds, so a computed source is an
  # expression Mutare may mutate but must not evaluate ahead of the call.
  defp source_treatment(_value), do: :lazy_expression

  defp report(seam, call), do: send(self(), {:piped_call_probe, seam, call})
end
