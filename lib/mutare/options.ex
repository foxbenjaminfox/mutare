defmodule Mutare.Options do
  @moduledoc """
  Validated configuration for a mutation run.

  `new/1` resolves a keyword list (or another `Options`) into a struct, validating every field up front. Invalid values raise `ArgumentError`. Passing the same options on the command line or in `.mutare.exs` uses the same validation; see `mix help mutare` for the full list of settable keys and their defaults.

  Runtime wiring, such as the resolved `Mutare.Project` and live-progress hooks, lives in `Mutare.Run.Context`, not in this struct.

  The fields and their types are listed in `t:t/0` below.
  """

  # `new/1` is the normalization boundary for every entry path: raw keyword
  # values and an existing struct are both validated into the canonical runtime
  # shape. Two things are deliberately *not* options: transform plumbing (`:file`,
  # `:start_id`, `:skip_ids`) is per-file machinery threaded by `Mutare.Schema`,
  # and the sandbox/project disjointness check lives in `Mutare.Sandbox` (it is
  # relational to `root`); here we only validate the shape of `:sandbox`.

  alias Mutare.Options.Parallelism
  alias Mutare.Options.Registry

  @type t :: %__MODULE__{
          paths: [String.t()],
          exclude: [String.t()],
          mutators: [Mutare.Mutator.Spec.t()] | nil,
          call_routes: list(),
          argument_marks: [Mutare.Mutator.mark_declaration()],
          skip_lifting: MapSet.t(Mutare.Lifting.skip_entry()),
          extensions: [Mutare.Extension.Spec.t()],
          expand_uses: boolean(),
          only_files: MapSet.t() | nil,
          only_lines: MapSet.t() | nil,
          test_selection: :tests | :coverage | :full,
          workers: pos_integer(),
          schedulers: pos_integer() | :all,
          partition_env: String.t() | nil,
          timeout: pos_integer() | nil,
          timeout_multiplier: number(),
          compile_timeout: pos_integer() | nil,
          probe_timeout: pos_integer() | nil,
          baseline_runs: pos_integer(),
          baseline_retries: non_neg_integer(),
          kill_runs: pos_integer(),
          confirm_timeouts: boolean(),
          harness_retries: non_neg_integer(),
          max_harness_error_rate: number() | nil,
          max_no_coverage: non_neg_integer() | nil,
          fail_on_poisoned: boolean(),
          fail_on_harness_error: boolean(),
          sandbox: String.t() | nil,
          keep_sandbox: boolean(),
          seed_app_build: boolean(),
          strict_ignores: boolean(),
          verify_invariants: boolean(),
          quiet: boolean(),
          verbose: boolean(),
          max_mutants: pos_integer() | nil,
          max_survivors: pos_integer() | nil,
          time_budget: String.t() | nil,
          min_score: number() | nil,
          reporters: [{:human | :json | :html | :sarif, String.t() | nil}]
        }

  # The struct, its `@keys` whitelist (`reject_unknown!/1`), and `new/1`'s per-field defaults
  # (via `opt/2`) all derive from the one `Mutare.Options.Registry` source, so a field's default
  # lives in exactly one place and the two construction paths (`defstruct` vs `new/1`) can't drift.
  @field_defaults Registry.defaults()

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
  `:sarif`).

      iex> Mutare.Options.formats()
      [:human, :json, :html, :sarif]
  """
  @spec formats() :: [atom()]
  def formats, do: @formats

  @doc """
  The renderer module for an output `format`.

  `:human` maps to `Mutare.Report`; machine formats map to modules under
  `Mutare.Report.*`.
  """
  @spec renderer(atom()) :: module()
  def renderer(format), do: Keyword.fetch!(@format_renderers, format)

  @doc """
  Resolve and validate options.

  Accepts a keyword list or an existing `Options` struct. Raises `ArgumentError`
  on an unknown key or invalid value.

  `:workers` (concurrent mutant runs) and `:schedulers` (scheduler threads per
  run) divide `System.schedulers_online/0` between them, so the runs do not
  oversubscribe the CPU. Whichever is omitted is derived from the other, workers
  never above the default's clamp; with neither, workers are half the schedulers
  capped at 4. `schedulers: :all` leaves
  every run every scheduler. Both are resolved here, so the struct carries
  concrete values.

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

      iex> opts = Mutare.Options.new(workers: 3, schedulers: :all)
      iex> {opts.workers, opts.schedulers}
      {3, :all}
  """
  @spec new(t() | keyword()) :: t()
  def new(%__MODULE__{} = options) do
    options
    |> Map.from_struct()
    |> Map.to_list()
    |> build()
  end

  def new(opts) when is_list(opts) do
    reject_unknown!(opts)
    reject_explicit_nil_mutators!(opts)
    build(opts)
  end

  defp build(opts) do
    Registry.specs()
    |> Enum.map(fn %{key: key, validate: validate} -> {key, validate.(opt(opts, key))} end)
    |> then(&struct(__MODULE__, &1))
    |> resolve_parallelism()
    |> validate_argument_mark_labels!()
  end

  # `:workers` and `:schedulers` share one budget, so they are defaulted together rather than
  # by their own validators — the one computed default.
  defp resolve_parallelism(%__MODULE__{workers: workers, schedulers: schedulers} = options) do
    {workers, schedulers} =
      Parallelism.resolve(workers, schedulers, System.schedulers_online())

    %{options | workers: workers, schedulers: schedulers}
  end

  # The one cross-field check: a configured `argument_marks:` label must be one some mutator
  # *declares positions for* (`Mutare.Mutator.declared_labels/1`) — a mark's meaning lives in the
  # mutators that read it, so a label nobody declares would mark positions nobody looks at. The
  # known set is the enabled mutators' labels plus every built-in family's (so `--mutators`
  # narrowing a run below `:integer` never invalidates a `:timeout` entry); a `nil` `:mutators` is
  # the full built-in set. Checked here, once per run, rather than inside the parallel transform.
  defp validate_argument_mark_labels!(%__MODULE__{argument_marks: []} = options), do: options

  defp validate_argument_mark_labels!(
         %__MODULE__{argument_marks: marks, mutators: mutators} = options
       ) do
    known =
      MapSet.union(
        Mutare.Mutator.declared_labels(mutators || []),
        Mutare.Mutator.declared_labels(Mutare.Mutators.all())
      )

    Enum.each(marks, fn {module, fun, arity, _positions, label} ->
      unless MapSet.member?(known, label) do
        raise ArgumentError,
              ":argument_marks entry #{inspect(module)}.#{fun}/#{arity} uses label " <>
                "#{inspect(label)}, which no configured mutator declares positions for (known: " <>
                "#{inspect(Enum.sort(known))}). A mark's meaning lives in the mutator that reads " <>
                "it — enable that mutator, or use a :raw route in :call_routes to leave the " <>
                "position alone for every family."
      end
    end)

    options
  end

  # Read option `key` from `opts`, falling back to its registry default — the one place `new/1`'s
  # defaults come from, so they can't drift from `defstruct`'s. (`:workers` and `:schedulers`
  # default to `nil` there and are computed afterwards, by `resolve_parallelism/1`.)
  defp opt(opts, key), do: Keyword.get(opts, key, Keyword.fetch!(@field_defaults, key))

  defp reject_unknown!(opts) do
    case Enum.uniq(Keyword.keys(opts)) -- @keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "unknown option(s) #{inspect(unknown)}; valid: #{inspect(@keys)}"
    end
  end

  # An explicit `mutators: nil` is an error; a caller asks for the default set by omitting the key.
  # The registry's `:mutators` validator can't enforce that, because `nil` reaches it on every path
  # that means "default set": an omitted key resolves to the `nil` default, and the struct clause of
  # `new/1` passes a resolved default set as `nil`. Every other non-list value needs no check here —
  # it reaches that validator's catch-all.
  defp reject_explicit_nil_mutators!(opts) do
    if Keyword.fetch(opts, :mutators) == {:ok, nil} do
      raise ArgumentError, ":mutators must be omitted or set to a list of mutators, got: nil"
    end
  end
end
