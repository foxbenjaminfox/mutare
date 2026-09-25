defmodule Mutare.Transform.Resolve.Arguments do
  @moduledoc false

  # Resolution observes the same syntax boundaries as analysis. A classifier sees arguments
  # before this descent; only regions its route permits core to interpret enter Resolve.
  # In particular, neither nested classifiers nor pipe desugaring run in foreign syntax.
  alias Mutare.Transform.KeywordRouting

  # `decode` reads a keyword route against the argument. The written call the route was
  # stamped on takes the one strict reading: a positional list that does not fit the pairs
  # is the route's error, raised there (`KeywordRouting.decode!/2`, the default). A call a
  # mutator rebuilt (`Resolve.reroute/2`) takes the lenient one every later reader takes,
  # since a static route's count may no longer fit its pairs (`KeywordRouting.decode/2`).
  @type decode :: (Macro.t(), KeywordRouting.routing() -> KeywordRouting.decoded())

  @spec walk([Macro.t()], nil | :skip | [term()], (Macro.t() -> Macro.t()), decode()) ::
          [Macro.t()]
  def walk(args, routes, resolve, decode \\ &KeywordRouting.decode!/2)

  def walk(args, :skip, _resolve, _decode), do: args
  def walk(args, nil, resolve, _decode), do: Enum.map(args, resolve)

  # ArgumentRoutes has already established one treatment per argument.
  def walk(args, routes, resolve, decode) when is_list(routes),
    do: Enum.zip_with(args, routes, &position(&1, &2, resolve, decode))

  defp position(arg, :raw, _resolve, _decode), do: arg
  defp position(arg, {:hosted, _hosts}, _resolve, _decode), do: arg

  defp position(arg, {:keyword, _} = treatment, resolve, decode),
    do: keyword_position(arg, treatment, resolve, decode)

  defp position(arg, {:keyed, _, _} = treatment, resolve, decode),
    do: keyword_position(arg, treatment, resolve, decode)

  defp position(arg, _treatment, resolve, _decode), do: resolve.(arg)

  defp keyword_position(arg, treatment, resolve, decode) do
    case decode.(arg, treatment) do
      {:pairs, pairs, rewrap} ->
        pairs
        |> Enum.map(fn {{key, key_treatment}, {value, value_treatment}} ->
          {position(key, key_treatment, resolve, decode),
           position(value, value_treatment, resolve, decode)}
        end)
        |> rewrap.()

      {:whole, fallback} ->
        position(arg, fallback, resolve, decode)
    end
  end
end
