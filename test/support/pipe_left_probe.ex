defmodule Mutare.Test.PipeLeftDSL do
  @moduledoc """
  A fake query DSL with one composable macro, `stage/2`, whose first argument may be something
  that is *not* an Elixir value — the analog of Ecto's `from`, which accepts a schema alias or a
  binding declaration (`p in Post`) where a function would need an expression. Written piped,
  that argument is the `|>`'s left side, which the call node does not hold.
  """

  @doc "Thread `source` through, keeping it only when `condition` holds."
  defmacro stage(source, condition) do
    quote do
      if unquote(condition), do: unquote(source), else: []
    end
  end
end

defmodule Mutare.Test.PipeLeftProbe do
  @moduledoc """
  Reports the `Mutare.CallRouting.Call` each of an adapter's three seams is shown for a
  `Mutare.Test.PipeLeftDSL.stage/2` call — `c:Mutare.CallRouting.route_arguments/2`,
  `c:Mutare.Mutator.MacroHost.host/2`, and `Mutare.Calls.resolved_routed_call/1` from inside
  `c:Mutare.Mutator.mutate/2` — by sending `{:pipe_left_probe, seam, call}` to the process
  running the transform. It mutates nothing itself.

  Its classifier routes the piped position **by the shape of the left side**, which is what
  `pipe_left` exists for: a schema alias or a binding declaration is left `:raw` (an alias swap
  there is a broken query, not a mutant), and anything else is an ordinary `:expression`, so the
  upstream code keeps its mutants.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.CallRouting
  @behaviour Mutare.Mutator.MacroHost

  alias Mutare.CallRouting.{ArgumentRoutes, Call}

  @dsl Mutare.Test.PipeLeftDSL

  @impl Mutare.Mutator
  def name, do: :pipe_left_probe

  @impl Mutare.CallRouting
  def call_routes, do: [{@dsl, :stage, 2, :routing}]

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{@dsl, :stage, 2}]

  @impl Mutare.CallRouting
  def route_arguments(%Call{pipe_left: {:piped, left}} = call, _context) do
    report(:route_arguments, call)
    ArgumentRoutes.from_visible(call, [:hosted], piped: source_treatment(left))
  end

  def route_arguments(
        %Call{pipe_left: :unpiped, arguments: [source, _condition]} = call,
        _context
      ) do
    report(:route_arguments, call)
    ArgumentRoutes.from_visible(call, [source_treatment(source), :hosted])
  end

  @impl Mutare.Mutator.MacroHost
  def host(%Call{} = call, _context) do
    report(:host, call)
    []
  end

  @impl Mutare.Mutator
  def mutate(node, _context) do
    with %Call{module: @dsl} = call <- Mutare.Calls.resolved_routed_call(node) do
      report(:mutate, call)
    end

    :skip
  end

  defp source_treatment({:__aliases__, _meta, _segments}), do: :raw
  defp source_treatment({:in, _meta, [_binding, _queryable]}), do: :raw
  defp source_treatment(_value), do: :expression

  defp report(seam, call), do: send(self(), {:pipe_left_probe, seam, call})
end
