defmodule Mutare.Config do
  @moduledoc """
  Resolve Mutare options from an optional `.mutare.exs` file and CLI flags.

  CLI flags win over file config. The result is a keyword list that
  `Mutare.Options.new/1` validates and resolves into the `Mutare.Options` struct
  threaded through the rest of the pipeline.
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
  `:min_score`, `:sandbox`, `:full` (→ `test_selection: :full`). A `:mutators`
  value of `:all` (or none) resolves to "use the default set" by omitting the
  key, so `Mutare.Transform` picks it. Raises `ArgumentError` on an unknown
  mutator family.
  """
  @spec merge(keyword(), keyword()) :: keyword()
  def merge(file_config, flags) do
    file_config
    |> put_unless_nil(:paths, flags[:only] && [flags[:only]])
    |> put_unless_nil(:min_score, flags[:min_score])
    |> put_unless_nil(:sandbox, flags[:sandbox])
    |> put_unless_nil(:test_selection, flags[:full] && :full)
    |> put_unless_nil(:mutators, flags[:mutators] && parse_families(flags[:mutators]))
    |> normalize_mutators()
  end

  @doc """
  Resolve a list of mutators to modules. Each entry is either a built-in family
  atom (`:arithmetic`, `:relational`) or a module implementing `Mutare.Mutator`
  (a custom mutator). Raises `ArgumentError` on anything else.
  """
  @spec mutator_modules([atom() | module()]) :: [module()]
  def mutator_modules(mutators) when is_list(mutators) do
    Enum.map(mutators, &resolve!/1)
  end

  # --- internals -----------------------------------------------------------

  defp parse_families(csv) do
    # `to_atom`, not `to_existing_atom`: a typo'd family must reach `resolve!/1`
    # so it gets the descriptive `unknown_mutator_message`, not a bare
    # `ArgumentError` from atom-table lookup before we can explain it.
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
  end

  defp normalize_mutators(config) do
    case Keyword.get(config, :mutators, :all) do
      :all -> Keyword.delete(config, :mutators)
      mutators -> Keyword.put(config, :mutators, mutator_modules(mutators))
    end
  end

  defp resolve!(name) do
    cond do
      Map.has_key?(@registry, name) ->
        Map.fetch!(@registry, name)

      Mutare.Mutator.implemented_by?(name) ->
        name

      true ->
        raise ArgumentError, unknown_mutator_message(name)
    end
  end

  defp unknown_mutator_message(name) do
    base =
      "unknown mutator #{inspect(name)}: expected a built-in family " <>
        "(#{known_families()}) or a module implementing Mutare.Mutator"

    # A loaded module that just isn't a mutator gets a more specific nudge.
    if is_atom(name) and Code.ensure_loaded?(name) do
      base <> " (#{inspect(name)} is missing mutate/1 or name/0)"
    else
      base
    end
  end

  defp known_families, do: @registry |> Map.keys() |> Enum.map_join(", ", &to_string/1)

  defp put_unless_nil(config, _key, nil), do: config
  defp put_unless_nil(config, key, value), do: Keyword.put(config, key, value)
end
