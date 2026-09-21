defmodule Mutare.Test.ForeignPipeDSL do
  @moduledoc false

  # This language deliberately gives `|>` different semantics: the stage's argument is
  # the left operand of subtraction. Neither the pipe nor `stage/1` expands as Elixir.
  defmacro run(seed, fragment) do
    expression = expression(fragment)
    quote do: unquote(seed) + unquote(expression)
  end

  defmacro value(fragment), do: expression(fragment)

  defp expression({:|>, _, [left, {stage, _, [right]}]}) do
    operator = if stage == :stage, do: :-, else: :+
    {{:., [], [:erlang, operator]}, [], [right, left]}
  end

  # The host weaves an ordinary selector whose branches call value/1.
  defp expression(other), do: other
end

defmodule Mutare.Test.ForeignPipeHost do
  @moduledoc false
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.MacroHost
  @behaviour Mutare.CallRouting

  alias Mutare.CallRouting.{ArgumentRoutes, Call}
  alias Mutare.Mutator.MacroHost.Target
  alias Mutare.Test.ForeignPipeDSL

  def name, do: :foreign_pipe

  def call_routes do
    [
      {ForeignPipeDSL, :run, 2, :routing},
      {ForeignPipeDSL, :value, 1, :raw},
      {:*, :stage, :any, :routing}
    ]
  end

  def hosted_macros, do: [{ForeignPipeDSL, :run, 2}]

  def route_arguments(%Call{name: :run, arguments: [_seed, {:|>, _, _}]} = call),
    do: ArgumentRoutes.new(call, [:expression, :hosted])

  def route_arguments(%Call{name: :stage}),
    do: raise("core interpreted the DSL's stage as an Elixir call")

  def host(
        %Call{arguments: [_seed, {:|>, meta, [left, {:stage, smeta, args}]} = original]},
        _context
      ) do
    mutant = {:|>, meta, [left, {:sum, smeta, args}]}
    splice = fn {head, meta, [seed, _fragment]}, selector -> {head, meta, [seed, selector]} end
    wrap = fn fragment -> {{:., [], [ForeignPipeDSL, :value]}, [], [fragment]} end
    [Target.new(original, [mutant], splice, wrap: wrap)]
  end
end
