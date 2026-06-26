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
  Merge `file_config` with parsed CLI `flags` into a resolved options keyword list
  (what `Mutare.Options.new/1` validates). CLI flags win over file config: each set
  flag is translated to its option key and put over the file value; an unset flag
  leaves the file's value (or the option default) in place.

  The recognised flags and what they mean are documented for users in the
  `Mix.Tasks.Mutare` moduledoc — this is the translation layer, so it records only the
  mappings that aren't a 1:1 rename: a repeatable `--only` accumulates into `:paths`
  (each a directory or single `.ex` file, in order), `--line FILE:LINE` into
  `:only_lines`, `--full` sets `test_selection: :full`, and
  `--partition-db`/`--partition-env` resolve to `:partition_env`. A bare `:mutators`
  value of `:all` or `:builtins` (or none) resolves to "use the default set" by
  omitting the key, so `Mutare.Transform` picks it; a `:mutators` *list* is resolved
  through `Mutare.Mutators.resolve/1`, where the `:builtins` token expands to every
  built-in family in place (so `--mutators builtins,relational` works). Raises
  `ArgumentError` on an unknown mutator family.

      iex> opts = Mutare.Config.merge([paths: ["lib"], min_score: 70], only: "lib/billing", full: true)
      iex> {opts[:paths], opts[:min_score], opts[:test_selection]}
      {["lib/billing"], 70, :full}

      iex> Mutare.Config.merge([], format: "json", output: "mutare.json")[:reporters]
      [{:human, nil}, {:json, "mutare.json"}]
  """
  @spec merge(keyword(), keyword()) :: keyword()
  def merge(file_config, flags) do
    # Only the flags that need *translating* are spelled out here; the 1:1 pass-throughs are
    # folded in by `put_passthrough_flags/2` (the order is immaterial — distinct keys, each
    # `Keyword.put`). Keeping them apart makes the translations the only thing to read.
    file_config
    |> put_unless_nil(:paths, only_paths(flags))
    |> put_unless_nil(:exclude, exclude_globs(flags))
    |> put_unless_nil(:only_lines, parse_lines(flags))
    |> put_unless_nil(:test_selection, flags[:full] && :full)
    |> put_unless_nil(:partition_env, partition_env(flags))
    |> put_unless_nil(:mutators, flags[:mutators] && parse_families(flags[:mutators]))
    |> put_passthrough_flags(flags)
    |> normalize_mutators()
    |> resolve_reporters(flags)
  end

  # Flags forwarded straight through: same config key, value taken verbatim from `flags`
  # (and dropped when absent, like every other flag). Listed once so a new 1:1 flag is a
  # single addition and the translated flags in `merge/2` stay the focus.
  @passthrough_flags [
    :min_score,
    :sandbox,
    :keep_sandbox,
    :seed_app_build,
    :strict_ignores,
    :quiet,
    :baseline_runs,
    :harness_retries,
    :max_harness_error_rate,
    :max_mutants,
    :max_survivors,
    :workers,
    :timeout,
    :timeout_multiplier,
    :expand_uses
  ]

  defp put_passthrough_flags(config, flags) do
    Enum.reduce(@passthrough_flags, config, fn key, config ->
      put_unless_nil(config, key, flags[key])
    end)
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
  # `reporters:` list. Both `--format` and `--output` are **repeatable** (`:keep`)
  # and paired by position (the Nth `--format` with the Nth `--output`); a format
  # with no matching `--output` writes to stdout. With at least one file output, the
  # human report still prints to the console; if any machine format takes stdout the
  # human report is dropped (they would collide). The valid-format check is left to
  # `Mutare.Options`, so a typo'd `--format` gets the descriptive error there.
  defp resolve_reporters(config, flags) do
    case Keyword.get_values(flags, :format) do
      [] ->
        case Keyword.fetch(config, :reporters) do
          {:ok, reporters} -> Keyword.put(config, :reporters, normalize_reporters(reporters))
          :error -> config
        end

      formats ->
        outputs = Keyword.get_values(flags, :output)
        Keyword.put(config, :reporters, cli_reporters(formats, outputs))
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

  # Pair the Nth `--format` with the Nth `--output` (a format past the last
  # `--output` goes to stdout, `nil`); extra `--output`s beyond the formats are
  # ignored. Prepend the human console report unless some machine format already
  # owns stdout (a `nil` path), which it would collide with.
  defp cli_reporters(formats, outputs) do
    reporters =
      formats
      |> Enum.with_index()
      |> Enum.map(fn {format, i} -> {to_format(format), Enum.at(outputs, i)} end)

    if Enum.any?(reporters, fn {_format, path} -> is_nil(path) end) do
      reporters
    else
      [{:human, nil} | reporters]
    end
  end

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

  # `--only` is the CLI counterpart of a `.mutare.exs` `paths:` list (which is
  # inherently multi-valued). It is a **repeatable** flag (parsed `:keep`): each
  # `--only <path>` contributes one directory or single `.ex` file, accumulated in
  # source order into `:paths`. Absent (`[]`) leaves the key unset so the file config
  # / default (`["lib"]`) stands.
  defp only_paths(flags) do
    case Keyword.get_values(flags, :only) do
      [] -> nil
      paths -> paths
    end
  end

  defp normalize_mutators(config) do
    case Keyword.get(config, :mutators, :all) do
      # A bare `:all`/`:builtins` (not in a list) means "the default set" — drop the
      # key and let `Mutare.Transform` supply it. Inside a list, `:builtins` is instead
      # a group token `Mutare.Mutators.resolve/1` expands (see that module).
      token when token in [:all, :builtins] -> Keyword.delete(config, :mutators)
      mutators -> Keyword.put(config, :mutators, mutator_modules(mutators))
    end
  end

  # Per-worker partition env var. `--partition-env NAME` sets a custom name and
  # wins; the boolean convenience `--partition-db` enables it under the
  # `mix test --partitions` default `MIX_TEST_PARTITION`. Absent (or an explicit
  # `--no-partition-db`) leaves the key unset so the file config / default (off)
  # stands. See `Mutare.Runner.Partitions`.
  defp partition_env(flags) do
    cond do
      is_binary(flags[:partition_env]) -> flags[:partition_env]
      flags[:partition_db] == true -> "MIX_TEST_PARTITION"
      true -> nil
    end
  end

  defp put_unless_nil(config, _key, nil), do: config
  defp put_unless_nil(config, key, value), do: Keyword.put(config, key, value)
end
