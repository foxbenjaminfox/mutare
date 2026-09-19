defmodule Mutare.Test.PipeSyntaxDSL do
  @moduledoc false
  @behaviour Mutare.CallRouting

  @impl true
  def call_routes, do: Mutare.Test.PipeSyntaxMutator.call_routes()

  defmacro raw({:in, _, [binding, source]}, body) do
    quote do
      unquote(binding) = unquote(source)
      unquote(body)
    end
  end

  # Like a DSL's pattern escape, a pin may contain an expression. Evaluate its value
  # before handing the resulting pinned variable to Elixir's native match.
  defmacro pattern(pattern, value) do
    {pattern, bindings} =
      Macro.prewalk(pattern, [], fn
        {:^, meta, [expression]}, bindings ->
          var = Macro.unique_var(:pinned, __MODULE__)
          {{:^, meta, [var]}, bindings ++ [quote(do: unquote(var) = unquote(expression))]}

        node, bindings ->
          {node, bindings}
      end)

    quote do
      unquote_splicing(bindings)
      match?(unquote(pattern), unquote(value))
    end
  end

  defmacro binding(pattern, value), do: quote(do: unquote(pattern) = unquote(value))

  # A composable stage: its first argument is an ordinary value (the query-builder shape).
  defmacro plus(source, amount), do: quote(do: unquote(source) + unquote(amount))

  defmacro keyword([{:value, expression}], value),
    do: quote(do: unquote(expression) == unquote(value))

  defmacro keyed([{:value, expression}], value),
    do: quote(do: unquote(expression) == unquote(value))

  defmacro interpolated({:^, _, [expression]}, value),
    do: quote(do: unquote(expression) == unquote(value))

  defmacro interpolated(literal, value) when is_integer(literal),
    do: quote(do: unquote(literal) == unquote(value))
end

defmodule Mutare.Test.PipeSyntaxMutator do
  @moduledoc "Whole-call mutations on stages whose first argument must reach the macro as syntax."
  @behaviour Mutare.Mutator
  @behaviour Mutare.CallRouting

  alias Mutare.CallRouting.Call

  @impl true
  def name, do: :pipe_syntax

  @impl true
  def call_routes do
    [
      {Mutare.Test.PipeSyntaxDSL, :raw, 2, [:raw, :expression]},
      {Mutare.Test.PipeSyntaxDSL, :pattern, 2, [:pattern, :expression]},
      {Mutare.Test.PipeSyntaxDSL, :binding, 2, [:binding_pattern, :expression]},
      {Mutare.Test.PipeSyntaxDSL, :plus, 2, [:expression, :expression]},
      {Mutare.Test.PipeSyntaxDSL, :keyword, 2, [{:keyword, [:expression]}, :raw]},
      {Mutare.Test.PipeSyntaxDSL, :keyed, 2, [[:raw, value: :expression], :raw]},
      {Mutare.Test.PipeSyntaxDSL, :interpolated, 2, [:interpolated, :raw]}
    ]
  end

  @impl true
  def mutate(node) do
    case Mutare.Calls.resolved_routed_call(node) do
      %Call{module: Mutare.Test.PipeSyntaxDSL, name: name, arguments: args, rebuild: rebuild} ->
        [rebuild.(name, List.update_at(args, -1, fn _ -> Mutare.AST.literal(0) end))]

      _ ->
        :skip
    end
  end
end
