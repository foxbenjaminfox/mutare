defmodule Mutare.Options do
  @moduledoc """
  Validated options for a mutation run — the struct `Mutare.run/2` accepts.

  `new/1` resolves a keyword list (or another `Options`) into a struct,
  validating every field up front so a bad `:workers`, `:timeout`,
  `:test_selection`, `:paths`, and so on fails loudly with an `ArgumentError`
  rather than misbehaving deep in the run. Passing the same options on the
  command line or in `.mutare.exs` goes through the same validation — see
  `mix help mutare` for the full list of settable keys and their defaults.

  The fields and their types are listed in `t:t/0` below.
  """

  # `new/1` is idempotent on a struct, so the pipeline normalises once at each
  # public entry point and passes the struct down without re-validating. Two
  # things are deliberately *not* options: transform plumbing (`:file`,
  # `:start_id`, `:skip_ids`) is per-file machinery threaded by `Mutare.Schema`,
  # and the sandbox/project disjointness check lives in `Mutare.Sandbox` (it is
  # relational to `root`); here we only validate the shape of `:sandbox`.

  alias Mutare.{Project, Result, Site}
  alias Mutare.Sandbox.Command

  @type t :: %__MODULE__{
          paths: [String.t()],
          exclude: [String.t()],
          mutators: [Mutare.Mutator.Spec.t()] | nil,
          macros: [Mutare.Macro.Spec.t()],
          plugins: [Mutare.Plugin.Spec.t()],
          expand_uses: boolean(),
          only_files: MapSet.t() | nil,
          only_lines: MapSet.t() | nil,
          test_selection: :coverage | :full,
          workers: pos_integer(),
          partition_env: String.t() | nil,
          timeout: pos_integer() | nil,
          timeout_multiplier: number(),
          baseline_runs: pos_integer(),
          harness_retries: non_neg_integer(),
          max_harness_error_rate: number() | nil,
          sandbox: String.t() | nil,
          keep_sandbox: boolean(),
          seed_app_build: boolean(),
          strict_ignores: boolean(),
          quiet: boolean(),
          max_mutants: pos_integer() | nil,
          max_survivors: pos_integer() | nil,
          min_score: number() | nil,
          reporters: [{:human | :json | :html | :sarif, String.t() | nil}],
          reporter: (Result.t() -> any()) | nil,
          on_phase: (atom() | tuple() -> any()) | nil,
          on_start: (Site.t() -> any()) | nil,
          on_scan: (map() -> any()) | nil,
          project: Project.t() | nil
        }

  # Single source for the struct's fields + their defaults: `defstruct`, the `@keys` allow-list
  # (`reject_unknown!/1`), *and* `new/1`'s per-field defaults (via `opt/2`) all derive from this,
  # so a field's default lives in one place and they can't drift (a field in `defstruct` but
  # missing from `@keys` would otherwise make `new/1` reject a valid option; a `new/1` default out
  # of step with `defstruct` would make the two construction paths disagree).
  @field_defaults [
    paths: ["lib"],
    exclude: [],
    mutators: nil,
    macros: [],
    plugins: [],
    expand_uses: true,
    only_files: nil,
    only_lines: nil,
    test_selection: :coverage,
    workers: nil,
    partition_env: nil,
    timeout: nil,
    timeout_multiplier: 3.0,
    baseline_runs: 1,
    harness_retries: 2,
    max_harness_error_rate: 0.5,
    sandbox: nil,
    keep_sandbox: false,
    seed_app_build: true,
    strict_ignores: false,
    quiet: false,
    max_mutants: nil,
    max_survivors: nil,
    min_score: nil,
    reporters: [{:human, nil}],
    reporter: nil,
    on_phase: nil,
    on_start: nil,
    on_scan: nil,
    project: nil
  ]

  defstruct @field_defaults

  @keys Keyword.keys(@field_defaults)

  # Single source for the output formats and their renderer modules: `:human` is the console
  # report (`Mutare.Report`); the rest are the machine renderers under `Mutare.Report.*`. Both
  # `formats/0` (the valid set) and `renderer/1` (the format → renderer module) derive from this,
  # so the validated set and the dispatch can't drift. A keyword list keeps `formats/0` ordered.
  @format_renderers [
    human: Mutare.Report,
    json: Mutare.Report.Json,
    html: Mutare.Report.Html,
    sarif: Mutare.Report.Sarif
  ]
  @formats Keyword.keys(@format_renderers)

  @doc """
  The output formats a reporter entry may name (`:human`, `:json`, `:html`,
  `:sarif`) — the single source of truth, so `Mutare.Config` can map a CLI
  `--format` string without re-listing them or interning arbitrary input.

      iex> Mutare.Options.formats()
      [:human, :json, :html, :sarif]
  """
  @spec formats() :: [atom()]
  def formats, do: @formats

  @doc """
  The renderer module for an output `format` — `:human` → `Mutare.Report`, the rest the machine
  renderers under `Mutare.Report.*`. The format→module half of the `@format_renderers` single
  source `formats/0` shares, so the Mix task dispatches without re-listing the mapping.
  """
  @spec renderer(atom()) :: module()
  def renderer(format), do: Keyword.fetch!(@format_renderers, format)

  @doc """
  The 1-arity progress hook bound to `field` (`:reporter`/`:on_phase`/`:on_start`/`:on_scan`),
  or a no-op when unset — so `Mutare.Runner` and `Mutare.Schema` invoke it unconditionally
  without each re-stating the `|| fn _ -> :ok end` default. The single home for that default.
  """
  @spec hook(t(), atom()) :: (term() -> any())
  def hook(%__MODULE__{} = options, field) do
    # mutare:ignore[convention, return_value] the no-op's return is discarded (side-effect-only hook)
    Map.get(options, field) || fn _ -> :ok end
  end

  @doc """
  Resolve and validate options.

  Accepts a keyword list (typically `Mutare.Config.merge/2`'s output, plus
  `:only_files`/`:reporter`) or an existing `Options` (returned unchanged).
  Raises `ArgumentError` on an unknown key or an invalid value. `:workers`
  defaults to `System.schedulers_online/0`, resolved here so the struct always
  carries a concrete positive integer.

      iex> opts = Mutare.Options.new(
      ...>   paths: ["lib/billing"],
      ...>   workers: 2,
      ...>   mutators: [:arithmetic],
      ...>   reporters: [{:json, "mutare.json"}]
      ...> )
      iex> {opts.paths, opts.workers, Enum.map(opts.mutators, & &1.name), opts.reporters}
      {["lib/billing"], 2, [:arithmetic], [{:json, "mutare.json"}]}

      iex> opts = Mutare.Options.new(workers: 2)
      iex> Mutare.Options.new(opts) == opts
      true
  """
  @spec new(t() | keyword()) :: t()
  def new(%__MODULE__{} = options), do: options

  def new(opts) when is_list(opts) do
    reject_unknown!(opts)

    %__MODULE__{
      paths: validate_paths!(opt(opts, :paths)),
      exclude: validate_string_list!(:exclude, opt(opts, :exclude)),
      mutators: validate_mutators!(opt(opts, :mutators)),
      macros: validate_macros!(opt(opts, :macros)),
      plugins: validate_plugins!(opt(opts, :plugins)),
      expand_uses: validate_expand_uses!(opt(opts, :expand_uses)),
      only_files: validate_only_files!(opt(opts, :only_files)),
      only_lines: validate_only_lines!(opt(opts, :only_lines)),
      test_selection: validate_test_selection!(opt(opts, :test_selection)),
      workers: validate_workers!(opt(opts, :workers) || System.schedulers_online()),
      partition_env: validate_partition_env!(opt(opts, :partition_env)),
      timeout: validate_timeout!(opt(opts, :timeout)),
      timeout_multiplier: validate_multiplier!(opt(opts, :timeout_multiplier)),
      baseline_runs: validate_baseline_runs!(opt(opts, :baseline_runs)),
      harness_retries: validate_harness_retries!(opt(opts, :harness_retries)),
      max_harness_error_rate: validate_harness_error_rate!(opt(opts, :max_harness_error_rate)),
      sandbox: validate_sandbox!(opt(opts, :sandbox)),
      keep_sandbox: validate_keep_sandbox!(opt(opts, :keep_sandbox)),
      seed_app_build: validate_seed_app_build!(opt(opts, :seed_app_build)),
      strict_ignores: validate_strict_ignores!(opt(opts, :strict_ignores)),
      quiet: validate_quiet!(opt(opts, :quiet)),
      max_mutants: validate_max_mutants!(opt(opts, :max_mutants)),
      max_survivors: validate_max_survivors!(opt(opts, :max_survivors)),
      min_score: validate_min_score!(opt(opts, :min_score)),
      reporters: validate_reporters!(opt(opts, :reporters)),
      reporter: validate_reporter!(opt(opts, :reporter)),
      on_phase: validate_callback!(:on_phase, opt(opts, :on_phase)),
      on_start: validate_callback!(:on_start, opt(opts, :on_start)),
      on_scan: validate_callback!(:on_scan, opt(opts, :on_scan)),
      project: validate_project!(opt(opts, :project))
    }
  end

  # Read option `key` from `opts`, falling back to its `@field_defaults` default — the one place
  # `new/1`'s defaults come from, so they can't drift from `defstruct`'s. (`:workers` resolves its
  # `nil` default to `System.schedulers_online/0` at its call site, the lone computed default.)
  defp opt(opts, key), do: Keyword.get(opts, key, Keyword.fetch!(@field_defaults, key))

  # --- validators ----------------------------------------------------------

  defp reject_unknown!(opts) do
    case Enum.uniq(Keyword.keys(opts)) -- @keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "unknown option(s) #{inspect(unknown)}; valid: #{inspect(@keys)}"
    end
  end

  # The scalar validators below share one shape: return the value when a predicate holds,
  # else raise an `ArgumentError` naming the field. `validate!/3` is that shape;
  # `validate_nullable!/3` additionally lets `nil` through (an optional field). The
  # `, got: <value>` suffix is appended here, so each `msg` states only the requirement.
  defp validate!(value, pred, msg) do
    if pred.(value), do: value, else: raise(ArgumentError, "#{msg}, got: #{inspect(value)}")
  end

  defp validate_nullable!(nil, _pred, _msg), do: nil
  defp validate_nullable!(value, pred, msg), do: validate!(value, pred, msg)

  # Shared validation for the plain boolean fields: the `&is_boolean/1` predicate and the
  # "`:field` must be true or false" message live here once, so each boolean field's validator
  # is a one-line delegate carrying only its own option-semantics comment.
  defp validate_boolean!(field, value),
    do: validate!(value, &is_boolean/1, "#{inspect(field)} must be true or false")

  defp validate_paths!(paths),
    do:
      validate!(
        paths,
        fn p -> is_list(p) and p != [] and Enum.all?(p, &is_binary/1) end,
        ":paths must be a non-empty list of path strings"
      )

  defp validate_string_list!(key, value),
    do:
      validate!(
        value,
        fn v -> is_list(v) and Enum.all?(v, &is_binary/1) end,
        "#{inspect(key)} must be a list of strings"
      )

  # Resolve and validate `:mutators` through the one `Mutare.Mutators` catalog into
  # `Mutare.Mutator.Spec`s, so the direct API (`Mutare.run/2`, `Options.new/1`)
  # resolves family atoms, accepts `{module, opts}` configured entries, and rejects
  # non-mutator modules exactly as the CLI/`.mutare.exs` path does — a list already
  # resolved by `Mutare.Config` passes through unchanged (resolution is idempotent).
  # `nil` means "let `Mutare.Transform` pick its default set". `resolve/1` raises a
  # descriptive "unknown mutator" error on a bad entry; the non-list clause keeps
  # the clear "list of modules" message for an outright wrong shape.
  defp validate_mutators!(nil), do: nil

  defp validate_mutators!(mutators) when is_list(mutators),
    do: Mutare.Mutators.resolve(mutators)

  defp validate_mutators!(other) do
    raise ArgumentError, ":mutators must be a list of modules, got: #{inspect(other)}"
  end

  # Resolve and validate `:macros` through `Mutare.Macros` into `Mutare.Macro.Spec`s. The
  # resolution is purely syntactic (no reflection), so an entry naming a module that is not a
  # dependency of the Mutare process (e.g. `Ecto.Query`) is accepted. `nil`/absent means none;
  # the built-ins (`Kernel.match?`/`destructure`) and mutator-provided macros are merged later,
  # in `Mutare.Transform`. `Mutare.Macros.resolve/1` raises a descriptive error on a bad entry.
  defp validate_macros!(nil), do: []
  defp validate_macros!(macros) when is_list(macros), do: Mutare.Macros.resolve(macros)

  defp validate_macros!(other) do
    raise ArgumentError, ":macros must be a list of macro entries, got: #{inspect(other)}"
  end

  # `:plugins` (default `[]`) lists `Mutare.Plugin` entries — third-party extensions that
  # contribute known-macro routing (`macros/0`) and/or `use`-expansion overrides
  # (`expand_use/3`), e.g. a Gettext integration. Each entry is a bare module or a
  # `{module, opts}` pair (opts delivered to `expand_use/3`'s context), resolved to a
  # `Mutare.Plugin.Spec`; the module must be a loaded plugin. Resolution is by reflection (a
  # plugin module *is* on the Mutare process path, unlike a `:macros` module which is only
  # named). `Mutare.Plugin.validate!/1` is the single home for the check — shared with
  # `Mutare.Transform`, so a non-plugin fails loudly on either entry path. Plugins are not
  # mutators — they make the built-in mutators' work land, never produce mutations themselves.
  # An explicit `nil` (like `:macros`) means "none", coerced to `[]` rather than raising.
  defp validate_plugins!(nil), do: []
  defp validate_plugins!(plugins), do: Mutare.Plugin.validate!(plugins)

  # `:expand_uses` (default `true`) toggles the `use`-expansion pre-pass
  # (`Mutare.Transform.Uses`) that surfaces `import`/`alias` hidden behind `use`. `false`
  # freezes the pre-expansion behaviour (e.g. to debug or pin mutant counts).
  defp validate_expand_uses!(value), do: validate_boolean!(:expand_uses, value)

  defp validate_only_files!(nil), do: nil
  defp validate_only_files!(%MapSet{} = set), do: set
  defp validate_only_files!(list) when is_list(list), do: MapSet.new(list)

  defp validate_only_files!(other) do
    raise ArgumentError,
          ":only_files must be a MapSet, a list of paths, or nil, got: #{inspect(other)}"
  end

  # `:only_lines` (the `--line FILE:LINE` filter) scopes the *run* to the mutants on
  # specific `file:line` locations — a narrow rerun, e.g. to recheck one survivor the
  # report named. A `MapSet`/list of `{file, line}` pairs, normalised to a `MapSet`;
  # `nil` means no line filter. The `file` is a root-relative path (as shown in the
  # report) and `line` a positive integer, validated per entry so a bad pair fails at
  # the edge rather than silently matching nothing deep in `Mutare.Schema`.
  defp validate_only_lines!(nil), do: nil
  defp validate_only_lines!(%MapSet{} = set), do: validate_line_entries!(set)
  defp validate_only_lines!(list) when is_list(list), do: validate_line_entries!(MapSet.new(list))

  defp validate_only_lines!(other) do
    raise ArgumentError,
          ":only_lines must be a MapSet, a list of {file, line} tuples, or nil, got: #{inspect(other)}"
  end

  defp validate_line_entries!(set) do
    Enum.each(set, fn
      {file, line} when is_binary(file) and file != "" and is_integer(line) and line > 0 ->
        :ok

      bad ->
        raise ArgumentError,
              ":only_lines entries must be {file, line} with a non-empty path string and a " <>
                "positive integer line, got: #{inspect(bad)}"
    end)

    set
  end

  defp validate_test_selection!(mode),
    do: validate!(mode, &(&1 in [:coverage, :full]), ":test_selection must be :coverage or :full")

  defp validate_workers!(workers),
    do: validate!(workers, &(is_integer(&1) and &1 > 0), ":workers must be a positive integer")

  # `:partition_env` (default `nil` = off) names an env var each concurrent worker
  # is given a distinct partition id under (e.g. `MIX_TEST_PARTITION`), so a
  # stateful suite can pick a per-worker database. A non-empty string enables it;
  # `nil` disables. It must also not collide with a name Mutare itself sets on the
  # sandbox `mix` (the partition entry is *appended* to that env, so a duplicate key
  # would silently clobber e.g. `MIX_ENV`). See `Mutare.Runner.Partitions`.
  defp validate_partition_env!(value) do
    name =
      validate_nullable!(
        value,
        &(is_binary(&1) and &1 != ""),
        ":partition_env must be a non-empty string (an env var name) or nil"
      )

    validate_nullable!(
      name,
      &(&1 not in Command.reserved_env_names()),
      ":partition_env must not name a variable Mutare reserves " <>
        "(#{Enum.join(Command.reserved_env_names(), ", ")})"
    )
  end

  defp validate_timeout!(ms),
    do:
      validate_nullable!(
        ms,
        &(is_integer(&1) and &1 > 0),
        ":timeout must be a positive integer (milliseconds) or nil"
      )

  defp validate_multiplier!(multiplier),
    do:
      validate!(
        multiplier,
        &(is_number(&1) and &1 > 0),
        ":timeout_multiplier must be a positive number"
      )

  defp validate_harness_retries!(n),
    do:
      validate!(
        n,
        &(is_integer(&1) and &1 >= 0),
        ":harness_retries must be a non-negative integer"
      )

  # At least one run — you always need a green check; N>1 re-runs the baseline to
  # catch a test that disagrees with itself (`Mutare.Runner.Baseline`).
  defp validate_baseline_runs!(n),
    do:
      validate!(
        n,
        &(is_integer(&1) and &1 >= 1),
        ":baseline_runs must be a positive integer (>= 1)"
      )

  # nil disables the abort guard; otherwise a fraction (0.0..1.0) of the mutants
  # that *ran* — above it, the run aborts rather than report a hollowed-out score.
  defp validate_harness_error_rate!(rate),
    do:
      validate_nullable!(
        rate,
        &(is_number(&1) and &1 >= 0 and &1 <= 1),
        ":max_harness_error_rate must be a number between 0.0 and 1.0, or nil"
      )

  defp validate_sandbox!(path),
    do:
      validate_nullable!(
        path,
        &(is_binary(&1) and &1 != ""),
        ":sandbox must be a non-empty path string or nil"
      )

  defp validate_keep_sandbox!(value), do: validate_boolean!(:keep_sandbox, value)

  # When true (the default; `--no-seed-app-build` turns it off), a narrowed run seeds the
  # mutated app's own compiled `_build` so the one `mix compile` recompiles just the
  # metamutant file(s) — see `Mutare.Sandbox.Seed.app_build/4`. The escape hatch exists to
  # rule the optimisation out when diagnosing a surprising score, or to force a cold compile.
  defp validate_seed_app_build!(value), do: validate_boolean!(:seed_app_build, value)

  # When true (`--strict-ignores`), a `# mutare:ignore` directive that suppresses
  # no mutant fails the run instead of only warning (see
  # `Mutare.Ignore.ineffective/2`). Default `false` (warn only).
  defp validate_strict_ignores!(value), do: validate_boolean!(:strict_ignores, value)

  # When true (`--quiet`), the Mix task does not attach the live progress reporter
  # (`Mutare.Report.Live`), so nothing is written to stderr as the run proceeds —
  # for CI, or any time the live block is unwanted. The final report and any
  # machine outputs are unaffected. Default `false`. Inert in the direct API
  # (`Mutare.run/2` never starts `Live`); it only gates the Mix task's wiring.
  defp validate_quiet!(value), do: validate_boolean!(:quiet, value)

  # nil means no cap (run every mutant); otherwise an upper bound on the number of
  # mutants tested. The cap is applied by `Mutare.Schema` (it truncates the site
  # list to the first N), so the metamutant still embeds every mutant — only the
  # run is bounded.
  defp validate_max_mutants!(n),
    do:
      validate_nullable!(
        n,
        &(is_integer(&1) and &1 > 0),
        ":max_mutants must be a positive integer or nil"
      )

  # nil means no cap (run every mutant); otherwise stop the per-mutant run once
  # this many *survivors* (`:survived` results) have been found. Unlike
  # `:max_mutants` (a schema cap on candidate *sites*), this is enforced in the
  # runner's per-mutant loop — every mutant is still compiled in, the run just
  # halts early once enough survivors surface. See `Mutare.Runner`.
  defp validate_max_survivors!(n),
    do:
      validate_nullable!(
        n,
        &(is_integer(&1) and &1 > 0),
        ":max_survivors must be a positive integer or nil"
      )

  defp validate_min_score!(score),
    do:
      validate_nullable!(
        score,
        &(is_number(&1) and &1 >= 0 and &1 <= 100),
        ":min_score must be a number between 0 and 100, or nil"
      )

  # `:reporters` is the list of *output formats* (the single source of truth for
  # format validation). Distinct from `:reporter` below, the live per-mutant
  # progress callback. Each entry is `{format, path | nil}` — `nil` path = stdout.
  defp validate_reporters!(reporters) when is_list(reporters) do
    Enum.map(reporters, &validate_reporter_entry!/1)
  end

  defp validate_reporters!(other) do
    raise ArgumentError,
          ":reporters must be a list of {format, path | nil} tuples, got: #{inspect(other)}"
  end

  defp validate_reporter_entry!({format, path})
       when format in @formats and (is_nil(path) or (is_binary(path) and path != "")) do
    {format, path}
  end

  defp validate_reporter_entry!(other) do
    raise ArgumentError,
          ":reporters entries must be {format, path | nil} with format in " <>
            "#{inspect(@formats)}, got: #{inspect(other)}"
  end

  defp validate_reporter!(fun),
    do: validate_nullable!(fun, &is_function(&1, 1), ":reporter must be a 1-arity function")

  # `:on_phase` (a phase term), `:on_start` (a `Mutare.Site`) and `:on_scan` (a
  # `%{done, total, found}` scan-progress map) are the live progress hooks fired
  # alongside `:reporter` — `:on_scan` by `Mutare.Schema` during the pre-run scan,
  # the rest by the runner. All 1-arity, all optional (`nil` = no-op), validated
  # identically.
  defp validate_callback!(key, fun),
    do: validate_nullable!(fun, &is_function(&1, 1), "#{inspect(key)} must be a 1-arity function")

  # Derived state, not raw user config: the entry points (`Mutare.Runner.run/2`,
  # the Mix task) resolve a `Mutare.Project` from the target path + scope flags and
  # set it here. `nil` is treated as a single-app project downstream.
  defp validate_project!(nil), do: nil
  defp validate_project!(%Project{} = project), do: project

  defp validate_project!(other) do
    raise ArgumentError, ":project must be a Mutare.Project or nil, got: #{inspect(other)}"
  end
end
