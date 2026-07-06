defmodule Mutare.Config do
  @moduledoc """
  Translate Mutare options from an optional `.mutare.exs` file and CLI flags.

  CLI flags win over file config. The result is a raw keyword list that
  `Mutare.Options.new/1` normalizes and validates into the `Mutare.Options`
  struct threaded through the rest of the pipeline. This module owns CLI syntax
  and precedence only; it does not resolve runtime option values.

  The **1:1 passthrough** flags (whose CLI name is a plain rename of an option
  key) are derived from `Mutare.Options.Registry`, so this module only spells out
  the *exceptional* flags it actually translates (see `cli_switches/0` and the
  translations in `merge/2`).
  """

  alias Mutare.Options.Registry
  alias Mutare.Lifting

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
  Merge `file_config` with parsed CLI `flags` into an options keyword list for
  `Mutare.Options.new/1`. CLI flags win over file config: each set
  flag is translated to its option key and put over the file value; an unset flag
  leaves the file's value (or the option default) in place. For translated boolean
  flags, the negative form is a real override too: e.g. `--no-full` restores
  coverage-guided selection and `--no-partition-db` disables partitioning even when
  `.mutare.exs` enabled it.

  The recognised flags and what they mean are documented for users in the
  `Mix.Tasks.Mutare` moduledoc — this is the translation layer, so it records only the
  mappings that aren't a 1:1 rename: a repeatable `--only` accumulates into `:paths`
  (each a directory or single `.ex` file, in order), `--line FILE:LINE` into
  `:only_lines`, `--skip-lifting Module.fun/arity` into `:skip_lifting`,
  `--full`/`--no-full` and `--per-file`/`--no-per-file` resolve to
  `:test_selection`, and
  `--partition-db`/`--no-partition-db`/`--partition-env` resolve to
  `:partition_env`. A `:mutators`
  CLI value is translated from CSV into a list of names; `Mutare.Options` resolves
  those names, including the `:builtins` group token, through the mutator catalog.

      iex> opts = Mutare.Config.merge([paths: ["lib"], min_score: 70], only: "lib/billing", full: true)
      iex> {opts[:paths], opts[:min_score], opts[:test_selection]}
      {["lib/billing"], 70, :full}

      iex> Mutare.Config.merge([], report: "json:mutare.json")[:reporters]
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
    |> put_unless_nil(:skip_lifting, parse_skip_lifting(flags))
    |> put_translation(:test_selection, test_selection(flags))
    |> put_translation(:partition_env, partition_env(flags))
    |> put_unless_nil(:mutators, flags[:mutators] && parse_families(flags[:mutators]))
    |> put_passthrough_flags(flags)
    |> resolve_reporters(flags)
  end

  @doc """
  The CLI switches this module owns: the **exceptional**/translated flags whose mapping is *not* a
  1:1 passthrough (a repeatable accumulator, a renamed/derived key, or a `--no-` toggle handled in
  `merge/2`). The Mix task composes these with `Mutare.Options.Registry.cli_switches/0` (the
  passthrough options) and its own project/inspect flags into `OptionParser`'s strict switch list,
  so a flag's parse shape lives next to its translation.
  """
  @cli_switches [
    only: [:string, :keep],
    line: [:string, :keep],
    skip_lifting: [:string, :keep],
    exclude: [:string, :keep],
    mutators: :string,
    full: :boolean,
    per_file: :boolean,
    partition_db: :boolean,
    partition_env: :string,
    report: [:string, :keep]
  ]
  @spec cli_switches() :: keyword()
  def cli_switches, do: @cli_switches

  # Flags forwarded straight through: same config key, value taken verbatim from `flags`
  # (and dropped when absent). The set is `Mutare.Options.Registry.passthrough_keys/0` — the
  # options whose CLI flag is a plain `--key`/`--no-key` rename — so a new passthrough option is a
  # single registry entry, with nothing to add here.
  defp put_passthrough_flags(config, flags) do
    Enum.reduce(Registry.passthrough_keys(), config, fn key, config ->
      put_unless_nil(config, key, flags[key])
    end)
  end

  # Resolve output reporters. `--report FORMAT[:PATH]` (CLI) wins over a
  # `.mutare.exs` `reporters:` list. The flag is repeatable (`:keep`); an entry
  # without a `:PATH` writes to stdout. With only file outputs, the human report still
  # prints to the console; if any machine format takes stdout the human report is
  # dropped (they would collide). The valid-format check is left to `Mutare.Options`,
  # so a typo'd `--report jsoon:out.json` gets the descriptive error there.
  defp resolve_reporters(config, flags) do
    case Keyword.get_values(flags, :report) do
      [] ->
        config

      reports ->
        Keyword.put(config, :reporters, cli_reporters(reports))
    end
  end

  # Map a CLI report-format string to its atom *without* `String.to_atom/1` — which
  # would intern an arbitrary user string into the (never-collected) atom table. A
  # known format resolves to its atom; an unknown one is left as the raw string, so
  # `Mutare.Options` rejects it with the descriptive "format in [...]" error rather
  # than a bare lookup failure. `Mutare.Options.formats/0` is the single source.
  defp to_format(format) do
    Enum.find(Mutare.Options.formats(), format, &(Atom.to_string(&1) == format))
  end

  # Parse `FORMAT[:PATH]`, splitting only on the first colon. An absent path means
  # stdout (`nil`); an explicit empty path (`json:`) is preserved as `""` so
  # `Mutare.Options` rejects it with the existing reporter-entry validation.
  # Prepend the human console report unless some machine format already owns stdout
  # (a `nil` path), which it would collide with.
  defp cli_reporters(reports) do
    reporters = Enum.map(reports, &parse_report/1)

    if Enum.any?(reporters, fn {_format, path} -> is_nil(path) end) do
      reporters
    else
      [{:human, nil} | reporters]
    end
  end

  defp parse_report(report) do
    case String.split(report, ":", parts: 2) do
      [format] -> {to_format(format), nil}
      [format, path] -> {to_format(format), path}
    end
  end

  # --- internals -----------------------------------------------------------

  defp parse_families(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&parse_mutator(String.trim(&1)))
  end

  # A single `--mutators` entry, resolved *without* `String.to_atom/1` — which both
  # interns arbitrary user input into the never-collected atom table *and*, for a
  # module, yields the wrong atom: `String.to_atom("MyApp.M")` is `:"MyApp.M"`, not the
  # module `MyApp.M` (≡ `:"Elixir.MyApp.M"`), so the documented `--mutators MyApp.M`
  # custom-mutator example never resolved. Three cases, in order:
  #
  #   * a built-in **family** name or the `:builtins` group token resolves to
  #     its *existing* atom by string lookup (no interning);
  #   * a **module**-shaped name (`MyApp.MyMutator`) is built with `Module.concat/1`,
  #     producing the real module atom (and, helpfully, folding a leading `Elixir.`);
  #   * anything else passes through verbatim as a string, so the `Mutare.Mutators`
  #     resolver reports it with the descriptive "unknown mutator" message (its
  #     `Mutare.Mutator.Dispatch.implemented_by?/1` check is total over strings) — a
  #     typo'd family still reaches that explanation, and still without interning.
  defp parse_mutator(name) do
    cond do
      existing = known_mutator_name(name) -> existing
      # `Mutare.Lifting.module_alias?/1` is the one definition of "module-shaped CLI
      # string" (gating `Module.concat/1` so only module-shaped input is interned, not
      # arbitrary garbage) — shared with `--skip-lifting`, so the two flags accept the
      # same module syntax.
      Lifting.module_alias?(name) -> Module.concat(String.split(name, "."))
      true -> name
    end
  end

  # The existing atom matching a built-in family name or the group token, or `nil`.
  # String-compared against the live name set, so nothing is interned.
  defp known_mutator_name(name) do
    Enum.find([:builtins | Mutare.Mutators.families()], &(Atom.to_string(&1) == name))
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

  # `--skip-lifting Module.function/arity` keeps that function's clauses in place.
  # It is repeatable and translated into the same normalized entries the
  # `.mutare.exs` `skip_lifting:` option accepts.
  defp parse_skip_lifting(flags) do
    case Keyword.get_values(flags, :skip_lifting) do
      [] -> nil
      specs -> Enum.map(specs, &Lifting.parse_cli_spec!/1)
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

  # `:test_selection` is a three-level granularity ladder (`:full` ⊃ `:coverage` ⊃ `:tests`,
  # default `:tests`); two boolean flags reach the non-default rungs, with `--full` (safest) taking
  # precedence over `--per-file` when both are given:
  #
  #   * `--full` → `:full` (whole suite per covered mutant);
  #   * `--per-file` → `:coverage` (whole covering *files*, no per-test narrowing — the opt-out for
  #     stateful `async: false` suites where narrowing to individual tests could hide a kill);
  #   * `--no-full` / `--no-per-file` → the `:tests` default, each a real override of a
  #     `.mutare.exs` `test_selection:` other than `:tests`.
  #
  # An absent flag leaves the file config / default in place.
  defp test_selection(flags) do
    cond do
      flags[:full] == true -> {:set, :full}
      flags[:per_file] == true -> {:set, :coverage}
      Keyword.fetch(flags, :full) == {:ok, false} -> {:set, :tests}
      Keyword.fetch(flags, :per_file) == {:ok, false} -> {:set, :tests}
      true -> :unset
    end
  end

  # Per-worker partition env var. `--partition-env NAME` sets a custom name and
  # wins; the boolean convenience `--partition-db` enables it under the
  # `mix test --partitions` default `MIX_TEST_PARTITION`; `--no-partition-db`
  # disables partitioning and must override a `.mutare.exs` `partition_env: ...`.
  # Absent leaves the key unset so the file config / default (off) stands. See
  # `Mutare.Runner.Partitions`.
  defp partition_env(flags) do
    cond do
      is_binary(flags[:partition_env]) -> {:set, flags[:partition_env]}
      flags[:partition_db] == true -> {:set, "MIX_TEST_PARTITION"}
      Keyword.fetch(flags, :partition_db) == {:ok, false} -> {:set, nil}
      true -> :unset
    end
  end

  defp put_translation(config, _key, :unset), do: config
  defp put_translation(config, key, {:set, value}), do: Keyword.put(config, key, value)

  defp put_unless_nil(config, _key, nil), do: config
  defp put_unless_nil(config, key, value), do: Keyword.put(config, key, value)
end
