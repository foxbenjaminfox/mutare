defmodule Mutare.Config do
  @moduledoc """
  Resolve Mutare options from an optional `.mutare.exs` file and CLI flags.

  CLI flags win over file config. The result is a keyword list that
  `Mutare.Options.new/1` validates and resolves into the `Mutare.Options` struct
  threaded through the rest of the pipeline.
  """

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
  `:min_score`, `:sandbox`, `:keep_sandbox`, `:full` (→ `test_selection: :full`),
  `:baseline_runs`, `:harness_retries`, `:max_harness_error_rate`. A `:mutators`
  value of `:all`
  (or none) resolves to "use the default set" by omitting the key, so
  `Mutare.Transform` picks it. Raises `ArgumentError` on an unknown mutator
  family.
  """
  @spec merge(keyword(), keyword()) :: keyword()
  def merge(file_config, flags) do
    file_config
    |> put_unless_nil(:paths, flags[:only] && [flags[:only]])
    |> put_unless_nil(:min_score, flags[:min_score])
    |> put_unless_nil(:sandbox, flags[:sandbox])
    |> put_unless_nil(:keep_sandbox, flags[:keep_sandbox])
    |> put_unless_nil(:test_selection, flags[:full] && :full)
    |> put_unless_nil(:baseline_runs, flags[:baseline_runs])
    |> put_unless_nil(:harness_retries, flags[:harness_retries])
    |> put_unless_nil(:max_harness_error_rate, flags[:max_harness_error_rate])
    |> put_unless_nil(:mutators, flags[:mutators] && parse_families(flags[:mutators]))
    |> normalize_mutators()
    |> resolve_reporters(flags)
  end

  @doc """
  Resolve a list of mutators to modules via the `Mutare.Mutators` catalog. Each
  entry is either a built-in family atom (`:arithmetic`, `:relational`) or a
  module implementing `Mutare.Mutator`. Raises `ArgumentError` on anything else.
  """
  @spec mutator_modules([atom() | module()]) :: [module()]
  defdelegate mutator_modules(mutators), to: Mutare.Mutators, as: :resolve

  # Resolve output reporters. `--format` (CLI) wins over a `.mutare.exs`
  # `reporters:` list. With `--format` and `--output`, the machine format writes
  # to the file *and* the human report still prints to the console; with
  # `--format` alone the machine format takes stdout and the human report is
  # dropped (they would collide). The valid-format check is left to
  # `Mutare.Options`, so a typo'd `--format` gets the descriptive error there.
  defp resolve_reporters(config, flags) do
    case flags[:format] do
      nil ->
        case Keyword.fetch(config, :reporters) do
          {:ok, reporters} -> Keyword.put(config, :reporters, normalize_reporters(reporters))
          :error -> config
        end

      format ->
        Keyword.put(config, :reporters, cli_reporters(String.to_atom(format), flags[:output]))
    end
  end

  defp cli_reporters(format, nil), do: [{format, nil}]
  defp cli_reporters(format, output), do: [{:human, nil}, {format, output}]

  # Normalise a `.mutare.exs` `reporters:` list: a bare format atom means
  # "to stdout" (`{atom, nil}`); a `{format, path}` tuple is kept. Anything else
  # passes through untouched for `Mutare.Options` to reject with a clear message.
  defp normalize_reporters(reporters) when is_list(reporters) do
    Enum.map(reporters, fn
      format when is_atom(format) -> {format, nil}
      other -> other
    end)
  end

  defp normalize_reporters(other), do: other

  # --- internals -----------------------------------------------------------

  defp parse_families(csv) do
    # `to_atom`, not `to_existing_atom`: a typo'd family must reach the
    # `Mutare.Mutators` resolver so it gets the descriptive "unknown mutator"
    # message, not a bare `ArgumentError` from atom-table lookup before we can
    # explain it.
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

  defp put_unless_nil(config, _key, nil), do: config
  defp put_unless_nil(config, key, value), do: Keyword.put(config, key, value)
end
