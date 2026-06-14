defmodule Mutare.Config do
  @moduledoc """
  Resolve Mutare options from an optional `.mutare.exs` file and CLI flags.

  CLI flags win over file config. The result is a keyword list suitable for
  `Mutare.Schema.build/2` and `Mutare.Runner.run_with_schema/3`.
  """

  @registry %{
    arithmetic: Mutare.Mutators.Arithmetic,
    relational: Mutare.Mutators.Relational
  }

  @doc "Known mutator family => module."
  @spec registry() :: %{atom() => module()}
  def registry, do: @registry

  @doc "Load `.mutare.exs` from `root`, or `[]` when it is absent."
  @spec load(Path.t()) :: keyword()
  def load(root) do
    path = Path.join(root, ".mutare.exs")

    if File.exists?(path) do
      {config, _binding} = Code.eval_file(path)
      config
    else
      []
    end
  end

  @doc """
  Merge `file_config` with parsed CLI `flags` into resolved options.

  Recognised flags: `:only` (→ `:paths`), `:mutators` (CSV → modules),
  `:min_score`, `:sandbox`. A `:mutators` value of `:all` (or none) resolves to
  "use the default set" by omitting the key, so `Mutare.Transform` picks it.
  Raises `ArgumentError` on an unknown mutator family.
  """
  @spec merge(keyword(), keyword()) :: keyword()
  def merge(file_config, flags) do
    file_config
    |> put_unless_nil(:paths, flags[:only] && [flags[:only]])
    |> put_unless_nil(:min_score, flags[:min_score])
    |> put_unless_nil(:sandbox, flags[:sandbox])
    |> put_unless_nil(:mutators, flags[:mutators] && parse_families(flags[:mutators]))
    |> normalize_mutators()
  end

  @doc "Resolve mutator family atoms to modules. Raises on an unknown family."
  @spec mutator_modules([atom()]) :: [module()]
  def mutator_modules(families) when is_list(families) do
    Enum.map(families, &fetch_module!/1)
  end

  # --- internals -----------------------------------------------------------

  defp parse_families(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_existing_atom()))
  end

  defp normalize_mutators(config) do
    case Keyword.get(config, :mutators, :all) do
      :all -> Keyword.delete(config, :mutators)
      families -> Keyword.put(config, :mutators, mutator_modules(families))
    end
  end

  defp fetch_module!(family) do
    Map.get(@registry, family) ||
      raise ArgumentError,
            "unknown mutator family #{inspect(family)}; known: #{known_families()}"
  end

  defp known_families, do: @registry |> Map.keys() |> Enum.map_join(", ", &to_string/1)

  defp put_unless_nil(config, _key, nil), do: config
  defp put_unless_nil(config, key, value), do: Keyword.put(config, key, value)
end
