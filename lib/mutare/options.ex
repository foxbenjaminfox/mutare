defmodule Mutare.Options do
  @moduledoc """
  Validated, resolved options for a mutation run.

  This replaces the bare keyword list that used to thread through `Mutare.Config`,
  `Mutare.Schema`, `Mutare.Runner`, and `Mutare.Sandbox`. `new/1` resolves an
  (already config-merged) keyword list — or another `Options` — into a struct,
  validating every field up front, so a bad `:workers`, `:timeout`,
  `:test_selection`, `:paths`, `:sandbox`, `:keep_sandbox`, `:baseline_runs`,
  `:harness_retries`, or `:max_harness_error_rate` fails loudly at the edge with
  an `ArgumentError` instead of misbehaving silently deep in the pipeline.

  `new/1` is idempotent on a struct, so the pipeline can normalise once at each
  public entry point (`Mutare.run/2`, `Mutare.Schema.build/2`,
  `Mutare.Sandbox.prepare/3`) and pass the struct down without re-validating.

  Two things are deliberately *not* options:

    * Transform plumbing — `:file`, `:start_id`, `:skip_ids` — is per-file
      machinery threaded separately by `Mutare.Schema`, never user config.
    * The sandbox **disjointness** check (a sandbox must not overlap the project
      tree) lives in `Mutare.Sandbox`, since it is relational to `root`; here we
      only validate the shape of `:sandbox`.
  """

  alias Mutare.{Project, Result, Site}

  @type t :: %__MODULE__{
          paths: [String.t()],
          exclude: [String.t()],
          mutators: [Mutare.Mutator.Spec.t()] | nil,
          macros: [Mutare.Macro.Spec.t()],
          only_files: MapSet.t() | nil,
          test_selection: :coverage | :full,
          workers: pos_integer(),
          timeout: pos_integer() | nil,
          timeout_multiplier: number(),
          baseline_runs: pos_integer(),
          harness_retries: non_neg_integer(),
          max_harness_error_rate: number() | nil,
          sandbox: String.t() | nil,
          keep_sandbox: boolean(),
          min_score: number() | nil,
          reporters: [{:human | :json | :html | :sarif, String.t() | nil}],
          reporter: (Result.t() -> any()) | nil,
          on_phase: (atom() | tuple() -> any()) | nil,
          on_start: (Site.t() -> any()) | nil,
          on_scan: (map() -> any()) | nil,
          project: Project.t() | nil
        }

  defstruct paths: ["lib"],
            exclude: [],
            mutators: nil,
            macros: [],
            only_files: nil,
            test_selection: :coverage,
            workers: nil,
            timeout: nil,
            timeout_multiplier: 3.0,
            baseline_runs: 1,
            harness_retries: 1,
            max_harness_error_rate: 0.5,
            sandbox: nil,
            keep_sandbox: false,
            min_score: nil,
            reporters: [{:human, nil}],
            reporter: nil,
            on_phase: nil,
            on_start: nil,
            on_scan: nil,
            project: nil

  @keys ~w(paths exclude mutators macros only_files test_selection workers timeout
           timeout_multiplier baseline_runs harness_retries max_harness_error_rate
           sandbox keep_sandbox min_score reporters reporter on_phase on_start
           on_scan project)a

  # Output formats a reporter entry may name. `:human` is the console report
  # (`Mutare.Report`); the rest are the machine renderers under `Mutare.Report.*`.
  @formats ~w(human json html sarif)a

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
      paths: validate_paths!(Keyword.get(opts, :paths, ["lib"])),
      exclude: validate_string_list!(:exclude, Keyword.get(opts, :exclude, [])),
      mutators: validate_mutators!(Keyword.get(opts, :mutators)),
      macros: validate_macros!(Keyword.get(opts, :macros, [])),
      only_files: validate_only_files!(Keyword.get(opts, :only_files)),
      test_selection: validate_test_selection!(Keyword.get(opts, :test_selection, :coverage)),
      workers: validate_workers!(Keyword.get(opts, :workers) || System.schedulers_online()),
      timeout: validate_timeout!(Keyword.get(opts, :timeout)),
      timeout_multiplier: validate_multiplier!(Keyword.get(opts, :timeout_multiplier, 3.0)),
      baseline_runs: validate_baseline_runs!(Keyword.get(opts, :baseline_runs, 1)),
      harness_retries: validate_harness_retries!(Keyword.get(opts, :harness_retries, 1)),
      max_harness_error_rate:
        validate_harness_error_rate!(Keyword.get(opts, :max_harness_error_rate, 0.5)),
      sandbox: validate_sandbox!(Keyword.get(opts, :sandbox)),
      keep_sandbox: validate_keep_sandbox!(Keyword.get(opts, :keep_sandbox, false)),
      min_score: validate_min_score!(Keyword.get(opts, :min_score)),
      reporters: validate_reporters!(Keyword.get(opts, :reporters, [{:human, nil}])),
      reporter: validate_reporter!(Keyword.get(opts, :reporter)),
      on_phase: validate_callback!(:on_phase, Keyword.get(opts, :on_phase)),
      on_start: validate_callback!(:on_start, Keyword.get(opts, :on_start)),
      on_scan: validate_callback!(:on_scan, Keyword.get(opts, :on_scan)),
      project: validate_project!(Keyword.get(opts, :project))
    }
  end

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

  defp validate_only_files!(nil), do: nil
  defp validate_only_files!(%MapSet{} = set), do: set
  defp validate_only_files!(list) when is_list(list), do: MapSet.new(list)

  defp validate_only_files!(other) do
    raise ArgumentError,
          ":only_files must be a MapSet, a list of paths, or nil, got: #{inspect(other)}"
  end

  defp validate_test_selection!(mode),
    do: validate!(mode, &(&1 in [:coverage, :full]), ":test_selection must be :coverage or :full")

  defp validate_workers!(workers),
    do: validate!(workers, &(is_integer(&1) and &1 > 0), ":workers must be a positive integer")

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

  defp validate_keep_sandbox!(value),
    do: validate!(value, &is_boolean/1, ":keep_sandbox must be true or false")

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
