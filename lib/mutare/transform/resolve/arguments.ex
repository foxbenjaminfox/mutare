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

  # `preserve` is applied to what the route keeps as written — a skipped call's arguments, a
  # `:raw` or `:hosted` position. A file's walk returns it as parsed (the default); a mutant's
  # returns it as the source it spells (`Resolve.reroute/2`).
  @type opts :: [decode: decode(), preserve: (Macro.t() -> Macro.t())]

  @spec walk([Macro.t()], nil | :skip | [term()], (Macro.t() -> Macro.t()), opts()) ::
          [Macro.t()]
  def walk(args, routes, resolve, opts \\ []) do
    decode = Keyword.get(opts, :decode, &KeywordRouting.decode!/2)
    preserve = Keyword.get(opts, :preserve, &Function.identity/1)
    descend(args, routes, %{resolve: resolve, decode: decode, preserve: preserve})
  end

  defp descend(args, :skip, walker), do: walker.preserve.(args)
  defp descend(args, nil, walker), do: Enum.map(args, walker.resolve)

  # ArgumentRoutes has already established one treatment per argument.
  defp descend(args, routes, walker) when is_list(routes),
    do: Enum.zip_with(args, routes, &position(&1, &2, walker))

  defp position(arg, :raw, walker), do: walker.preserve.(arg)
  defp position(arg, {:hosted, _hosts}, walker), do: walker.preserve.(arg)

  defp position(arg, {:keyword, _} = treatment, walker),
    do: keyword_position(arg, treatment, walker)

  defp position(arg, {:keyed, _, _} = treatment, walker),
    do: keyword_position(arg, treatment, walker)

  defp position(arg, _treatment, walker), do: walker.resolve.(arg)

  defp keyword_position(arg, treatment, walker) do
    case walker.decode.(arg, treatment) do
      {:pairs, pairs, rewrap} ->
        pairs
        |> Enum.map(fn {{key, key_treatment}, {value, value_treatment}} ->
          {position(key, key_treatment, walker), position(value, value_treatment, walker)}
        end)
        |> rewrap.()

      {:whole, fallback} ->
        position(arg, fallback, walker)
    end
  end
end
