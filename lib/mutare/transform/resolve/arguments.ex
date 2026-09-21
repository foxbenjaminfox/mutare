defmodule Mutare.Transform.Resolve.Arguments do
  @moduledoc false

  # Resolution observes the same syntax boundaries as analysis. A classifier sees arguments
  # before this descent; only regions its route permits core to interpret enter Resolve.
  # In particular, neither nested classifiers nor pipe desugaring run in foreign syntax.
  alias Mutare.AST
  alias Mutare.Transform.Analyze.CallOptions

  @spec walk([Macro.t()], nil | :skip | [term()], (Macro.t() -> Macro.t())) :: [Macro.t()]
  def walk(args, :skip, _resolve), do: args
  def walk(args, nil, resolve), do: Enum.map(args, resolve)

  # ArgumentRoutes has already established one treatment per argument.
  def walk(args, routes, resolve) when is_list(routes),
    do: Enum.zip_with(args, routes, &position(&1, &2, resolve))

  defp position(arg, :raw, _resolve), do: arg
  defp position(arg, {:hosted, _hosts}, _resolve), do: arg

  defp position(arg, {:keyword, treatments}, resolve) do
    case CallOptions.keyword_pairs(arg) do
      {:ok, pairs, rewrap} ->
        CallOptions.validate_keyword_treatments!(pairs, treatments)

        pairs
        |> Enum.zip(treatments)
        |> Enum.map(fn {{key, value}, treatment} ->
          {key, position(value, treatment, resolve)}
        end)
        |> rewrap.()

      :error ->
        arg
    end
  end

  defp position(arg, {:keyed, leading, treatments}, resolve) do
    case CallOptions.keyword_pairs(arg) do
      {:ok, pairs, rewrap} ->
        inner = if leading == :interior, do: :expression, else: leading

        pairs
        |> Enum.map(fn {key, value} ->
          treatment = Keyword.get(treatments, AST.key_atom(key), inner)
          # Keys follow the leading descendant treatment, including calls in interpolated keys.
          {position(key, inner, resolve), position(value, treatment, resolve)}
        end)
        |> rewrap.()

      :error ->
        position(arg, leading, resolve)
    end
  end

  defp position(arg, _treatment, resolve), do: resolve.(arg)
end
