defmodule Mutare.Options do
  @moduledoc """
  Validated, resolved options for a mutation run.

  This replaces the bare keyword list that used to thread through `Mutare.Config`,
  `Mutare.Schema`, `Mutare.Runner`, and `Mutare.Sandbox`. `new/1` resolves an
  (already config-merged) keyword list — or another `Options` — into a struct,
  validating every field up front, so a bad `:workers`, `:timeout`,
  `:test_selection`, `:paths`, `:sandbox`, `:harness_retries`, or
  `:max_harness_error_rate` fails loudly at the edge with an `ArgumentError`
  instead of misbehaving silently deep in the pipeline.

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

  alias Mutare.Result

  @type t :: %__MODULE__{
          paths: [String.t()],
          exclude: [String.t()],
          mutators: [module()] | nil,
          only_files: MapSet.t() | nil,
          test_selection: :coverage | :full,
          workers: pos_integer(),
          timeout: pos_integer() | nil,
          timeout_multiplier: number(),
          harness_retries: non_neg_integer(),
          max_harness_error_rate: number() | nil,
          sandbox: String.t() | nil,
          min_score: number() | nil,
          reporters: [{:human | :json | :html | :sarif, String.t() | nil}],
          reporter: (Result.t() -> any()) | nil
        }

  defstruct paths: ["lib"],
            exclude: [],
            mutators: nil,
            only_files: nil,
            test_selection: :coverage,
            workers: nil,
            timeout: nil,
            timeout_multiplier: 3.0,
            harness_retries: 1,
            max_harness_error_rate: 0.5,
            sandbox: nil,
            min_score: nil,
            reporters: [{:human, nil}],
            reporter: nil

  @keys ~w(paths exclude mutators only_files test_selection workers timeout
           timeout_multiplier harness_retries max_harness_error_rate sandbox
           min_score reporters reporter)a

  # Output formats a reporter entry may name. `:human` is the console report
  # (`Mutare.Report`); the rest are the machine renderers under `Mutare.Report.*`.
  @formats ~w(human json html sarif)a

  @doc """
  Resolve and validate options.

  Accepts a keyword list (typically `Mutare.Config.merge/2`'s output, plus
  `:only_files`/`:reporter`) or an existing `Options` (returned unchanged).
  Raises `ArgumentError` on an unknown key or an invalid value. `:workers`
  defaults to `System.schedulers_online/0`, resolved here so the struct always
  carries a concrete positive integer.
  """
  @spec new(t() | keyword()) :: t()
  def new(%__MODULE__{} = options), do: options

  def new(opts) when is_list(opts) do
    reject_unknown!(opts)

    %__MODULE__{
      paths: validate_paths!(Keyword.get(opts, :paths, ["lib"])),
      exclude: validate_string_list!(:exclude, Keyword.get(opts, :exclude, [])),
      mutators: validate_mutators!(Keyword.get(opts, :mutators)),
      only_files: validate_only_files!(Keyword.get(opts, :only_files)),
      test_selection: validate_test_selection!(Keyword.get(opts, :test_selection, :coverage)),
      workers: validate_workers!(Keyword.get(opts, :workers) || System.schedulers_online()),
      timeout: validate_timeout!(Keyword.get(opts, :timeout)),
      timeout_multiplier: validate_multiplier!(Keyword.get(opts, :timeout_multiplier, 3.0)),
      harness_retries: validate_harness_retries!(Keyword.get(opts, :harness_retries, 1)),
      max_harness_error_rate:
        validate_harness_error_rate!(Keyword.get(opts, :max_harness_error_rate, 0.5)),
      sandbox: validate_sandbox!(Keyword.get(opts, :sandbox)),
      min_score: validate_min_score!(Keyword.get(opts, :min_score)),
      reporters: validate_reporters!(Keyword.get(opts, :reporters, [{:human, nil}])),
      reporter: validate_reporter!(Keyword.get(opts, :reporter))
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

  defp validate_paths!(paths) do
    if is_list(paths) and paths != [] and Enum.all?(paths, &is_binary/1) do
      paths
    else
      raise ArgumentError,
            ":paths must be a non-empty list of path strings, got: #{inspect(paths)}"
    end
  end

  defp validate_string_list!(key, value) do
    if is_list(value) and Enum.all?(value, &is_binary/1) do
      value
    else
      raise ArgumentError, "#{inspect(key)} must be a list of strings, got: #{inspect(value)}"
    end
  end

  # Resolve and validate `:mutators` through the one `Mutare.Mutators` catalog, so
  # the direct API (`Mutare.run/2`, `Options.new/1`) resolves family atoms and
  # rejects non-mutator modules exactly as the CLI/`.mutare.exs` path does — a
  # built-in already mapped to a module by `Mutare.Config` passes through
  # unchanged (resolution is idempotent). `nil` means "let `Mutare.Transform` pick
  # its default set". The shape check stays here so a non-atom element (e.g. a
  # string) gets the clear "list of modules" error, not an "unknown mutator" one.
  defp validate_mutators!(nil), do: nil

  defp validate_mutators!(modules) when is_list(modules) do
    if Enum.all?(modules, &is_atom/1) do
      Mutare.Mutators.resolve(modules)
    else
      raise ArgumentError, ":mutators must be a list of modules, got: #{inspect(modules)}"
    end
  end

  defp validate_mutators!(other) do
    raise ArgumentError, ":mutators must be a list of modules, got: #{inspect(other)}"
  end

  defp validate_only_files!(nil), do: nil
  defp validate_only_files!(%MapSet{} = set), do: set
  defp validate_only_files!(list) when is_list(list), do: MapSet.new(list)

  defp validate_only_files!(other) do
    raise ArgumentError,
          ":only_files must be a MapSet, a list of paths, or nil, got: #{inspect(other)}"
  end

  defp validate_test_selection!(mode) when mode in [:coverage, :full], do: mode

  defp validate_test_selection!(other) do
    raise ArgumentError, ":test_selection must be :coverage or :full, got: #{inspect(other)}"
  end

  defp validate_workers!(workers) when is_integer(workers) and workers > 0, do: workers

  defp validate_workers!(other) do
    raise ArgumentError, ":workers must be a positive integer, got: #{inspect(other)}"
  end

  defp validate_timeout!(nil), do: nil
  defp validate_timeout!(ms) when is_integer(ms) and ms > 0, do: ms

  defp validate_timeout!(other) do
    raise ArgumentError,
          ":timeout must be a positive integer (milliseconds) or nil, got: #{inspect(other)}"
  end

  defp validate_multiplier!(multiplier) when is_number(multiplier) and multiplier > 0,
    do: multiplier

  defp validate_multiplier!(other) do
    raise ArgumentError, ":timeout_multiplier must be a positive number, got: #{inspect(other)}"
  end

  defp validate_harness_retries!(n) when is_integer(n) and n >= 0, do: n

  defp validate_harness_retries!(other) do
    raise ArgumentError, ":harness_retries must be a non-negative integer, got: #{inspect(other)}"
  end

  # nil disables the abort guard; otherwise a fraction (0.0..1.0) of the mutants
  # that *ran* — above it, the run aborts rather than report a hollowed-out score.
  defp validate_harness_error_rate!(nil), do: nil

  defp validate_harness_error_rate!(rate) when is_number(rate) and rate >= 0 and rate <= 1,
    do: rate

  defp validate_harness_error_rate!(other) do
    raise ArgumentError,
          ":max_harness_error_rate must be a number between 0.0 and 1.0, or nil, " <>
            "got: #{inspect(other)}"
  end

  defp validate_sandbox!(nil), do: nil
  defp validate_sandbox!(path) when is_binary(path) and path != "", do: path

  defp validate_sandbox!(other) do
    raise ArgumentError, ":sandbox must be a non-empty path string or nil, got: #{inspect(other)}"
  end

  defp validate_min_score!(nil), do: nil
  defp validate_min_score!(score) when is_number(score) and score >= 0 and score <= 100, do: score

  defp validate_min_score!(other) do
    raise ArgumentError,
          ":min_score must be a number between 0 and 100, or nil, got: #{inspect(other)}"
  end

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

  defp validate_reporter!(nil), do: nil
  defp validate_reporter!(fun) when is_function(fun, 1), do: fun

  defp validate_reporter!(other) do
    raise ArgumentError, ":reporter must be a 1-arity function, got: #{inspect(other)}"
  end
end
