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

  Recognised flags: `:only` (→ `:paths`; a directory to scan or a single `.ex`
  file), `:line` (repeatable → `:only_lines`; a `FILE:LINE` to scope the run to one
  file:line's mutants), `:exclude` (repeatable → list of glob strings), `:mutators` (CSV → modules),
  `:min_score`, `:sandbox`, `:keep_sandbox`, `:full` (→ `test_selection: :full`),
  `:baseline_runs`, `:harness_retries`, `:max_harness_error_rate`,
  `:max_mutants`, `:workers`, `:timeout`, `:timeout_multiplier`,
  `:expand_uses` (`--no-expand-uses` disables `use`-expansion). A `:mutators`
  value of `:all`
  (or none) resolves to "use the default set" by omitting the key, so
  `Mutare.Transform` picks it. Raises `ArgumentError` on an unknown mutator
  family.

      iex> opts = Mutare.Config.merge([paths: ["lib"], min_score: 70], only: "lib/billing", full: true)
      iex> {opts[:paths], opts[:min_score], opts[:test_selection]}
      {["lib/billing"], 70, :full}

      iex> Mutare.Config.merge([], format: "json", output: "mutare.json")[:reporters]
      [{:human, nil}, {:json, "mutare.json"}]
  """
  @spec merge(keyword(), keyword()) :: keyword()
  def merge(file_config, flags) do
    file_config
    |> put_unless_nil(:paths, flags[:only] && [flags[:only]])
    |> put_unless_nil(:exclude, exclude_globs(flags))
    |> put_unless_nil(:only_lines, parse_lines(flags))
    |> put_unless_nil(:min_score, flags[:min_score])
    |> put_unless_nil(:sandbox, flags[:sandbox])
    |> put_unless_nil(:keep_sandbox, flags[:keep_sandbox])
    |> put_unless_nil(:test_selection, flags[:full] && :full)
    |> put_unless_nil(:baseline_runs, flags[:baseline_runs])
    |> put_unless_nil(:harness_retries, flags[:harness_retries])
    |> put_unless_nil(:max_harness_error_rate, flags[:max_harness_error_rate])
    |> put_unless_nil(:max_mutants, flags[:max_mutants])
    |> put_unless_nil(:workers, flags[:workers])
    |> put_unless_nil(:timeout, flags[:timeout])
    |> put_unless_nil(:timeout_multiplier, flags[:timeout_multiplier])
    |> put_unless_nil(:expand_uses, flags[:expand_uses])
    |> put_unless_nil(:mutators, flags[:mutators] && parse_families(flags[:mutators]))
    |> normalize_mutators()
    |> resolve_reporters(flags)
  end

  @doc """
  Resolve a list of mutators to `Mutare.Mutator.Spec`s via the `Mutare.Mutators`
  catalog. Each entry is a built-in family atom (`:arithmetic`, `:relational`), a
  module implementing `Mutare.Mutator`, or a `{module, opts}` configured pair.
  Raises `ArgumentError` on anything else.

      iex> Mutare.Config.mutator_modules([:arithmetic]) |> Enum.map(& &1.module)
      [Mutare.Mutators.Arithmetic]
  """
  @spec mutator_modules([atom() | module() | {atom() | module(), term()}]) ::
          [Mutare.Mutator.Spec.t()]
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
        Keyword.put(config, :reporters, cli_reporters(to_format(format), flags[:output]))
    end
  end

  # Map a CLI `--format` string to its atom *without* `String.to_atom/1` — which
  # would intern an arbitrary user string into the (never-collected) atom table. A
  # known format resolves to its atom; an unknown one is left as the raw string, so
  # `Mutare.Options` rejects it with the descriptive "format in [...]" error rather
  # than a bare lookup failure. `Mutare.Options.formats/0` is the single source.
  defp to_format(format) do
    Enum.find(Mutare.Options.formats(), format, &(Atom.to_string(&1) == format))
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

  # `--line FILE:LINE` scopes the run to the mutants on specific `file:line` locations —
  # a narrow rerun (e.g. to recheck one survivor, whose `file:line` the report prints
  # verbatim). It is a **repeatable** flag (parsed `:keep`): each `--line` contributes one
  # `{file, line}` pair, accumulated into `:only_lines`. Absent leaves the key unset (no
  # line filter). `Mutare.Options` then validates the pairs; `Mutare.Schema` applies them.
  defp parse_lines(flags) do
    case Keyword.get_values(flags, :line) do
      [] -> nil
      specs -> Enum.map(specs, &parse_line_spec/1)
    end
  end

  # `"lib/foo.ex:42"` → `{"lib/foo.ex", 42}`. Split on the *last* colon so a path may
  # itself contain one; the trailing segment must be a positive integer line number.
  # Anything else is a usage error, raised as an `ArgumentError` the Mix task surfaces
  # as a clean failure (it rescues `Config.merge/2`).
  defp parse_line_spec(spec) do
    with {file_parts, [line_str]} <- spec |> String.split(":") |> Enum.split(-1),
         file when file != "" <- Enum.join(file_parts, ":"),
         {line, ""} when line > 0 <- Integer.parse(line_str) do
      {file, line}
    else
      _ ->
        raise ArgumentError,
              "--line expects FILE:LINE (e.g. lib/foo.ex:42), got: #{inspect(spec)}"
    end
  end

  # `--exclude` is the CLI counterpart of a `.mutare.exs` `exclude:` list. It is a
  # **repeatable** flag (parsed `:keep`), so each `--exclude <glob>` contributes one
  # path glob, accumulated in source order; absent (`[]`) leaves the key unset so the
  # file config / default stands.
  defp exclude_globs(flags) do
    case Keyword.get_values(flags, :exclude) do
      [] -> nil
      globs -> globs
    end
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
