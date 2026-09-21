defmodule Mutare.Transform.Resolve.Arguments do
  @moduledoc false

  # Resolution observes the same syntax boundaries as analysis. A classifier sees arguments
  # before this descent; only regions its route permits core to interpret enter Resolve.
  # In particular, neither nested classifiers nor pipe desugaring run in foreign syntax.
  alias Mutare.Transform.KeywordRouting

  @spec walk([Macro.t()], nil | :skip | [term()], (Macro.t() -> Macro.t())) :: [Macro.t()]
  def walk(args, :skip, _resolve), do: args
  def walk(args, nil, resolve), do: Enum.map(args, resolve)

  # ArgumentRoutes has already established one treatment per argument.
  def walk(args, routes, resolve) when is_list(routes),
    do: Enum.zip_with(args, routes, &position(&1, &2, resolve))

  defp position(arg, :raw, _resolve), do: arg
  defp position(arg, {:hosted, _hosts}, _resolve), do: arg

  defp position(arg, {:keyword, _} = treatment, resolve),
    do: keyword_position(arg, treatment, resolve)

  defp position(arg, {:keyed, _, _} = treatment, resolve),
    do: keyword_position(arg, treatment, resolve)

  defp position(arg, _treatment, resolve), do: resolve.(arg)

  defp keyword_position(arg, treatment, resolve) do
    case KeywordRouting.decode(arg, treatment) do
      {:pairs, pairs, rewrap} ->
        pairs
        |> Enum.map(fn {{key, key_treatment}, {value, value_treatment}} ->
          {position(key, key_treatment, resolve), position(value, value_treatment, resolve)}
        end)
        |> rewrap.()

      {:whole, fallback} ->
        position(arg, fallback, resolve)
    end
  end
end
