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

  alias Mutare.Options.Registry

  @type t :: %__MODULE__{
          paths: [String.t()],
          exclude: [String.t()],
          mutators: [Mutare.Mutator.Spec.t()] | nil,
          macro_routes: list(),
          skip_lifting: MapSet.t(Mutare.Lifting.skip_entry()),
          extensions: [Mutare.Extension.Spec.t()],
          expand_uses: boolean(),
          only_files: MapSet.t() | nil,
          only_lines: MapSet.t() | nil,
          test_selection: :tests | :coverage | :full,
          workers: pos_integer(),
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
          quiet: boolean(),
          verbose: boolean(),
          max_mutants: pos_integer() | nil,
          max_survivors: pos_integer() | nil,
          min_score: number() | nil,
          reporters: [{:human | :json | :html | :sarif, String.t() | nil}]
        }

  # The struct, its `@keys` allow-list (`reject_unknown!/1`), and `new/1`'s per-field defaults
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
  on an unknown key or invalid value. `:workers` defaults to half
  `System.schedulers_online/0` capped at 4 (each worker is a full `mix test`
  BEAM that uses every scheduler, so the useful concurrency is a small constant,
  not a fraction of the cores), resolved here so the struct carries a concrete
  positive integer.

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
  def new(%__MODULE__{} = options) do
    options
    |> Map.from_struct()
    |> Map.to_list()
    |> build()
  end

  def new(opts) when is_list(opts) do
    reject_unknown!(opts)
    reject_invalid_mutators_shape!(opts)
    build(opts)
  end

  defp build(opts) do
    Registry.specs()
    |> Enum.map(fn %{key: key, validate: validate} -> {key, validate.(opt(opts, key))} end)
    |> then(&struct(__MODULE__, &1))
  end

  # Read option `key` from `opts`, falling back to its registry default — the one place `new/1`'s
  # defaults come from, so they can't drift from `defstruct`'s. (`:workers`'s `nil` default is
  # resolved to half `System.schedulers_online/0` capped at 4 inside its validator, the lone
  # computed default.)
  defp opt(opts, key), do: Keyword.get(opts, key, Keyword.fetch!(@field_defaults, key))

  defp reject_unknown!(opts) do
    case Enum.uniq(Keyword.keys(opts)) -- @keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "unknown option(s) #{inspect(unknown)}; valid: #{inspect(@keys)}"
    end
  end

  defp reject_invalid_mutators_shape!(opts) do
    if Keyword.has_key?(opts, :mutators) and not is_list(Keyword.fetch!(opts, :mutators)) do
      raise ArgumentError,
            ":mutators must be omitted or set to a list of mutators, got: " <>
              inspect(Keyword.fetch!(opts, :mutators))
    end
  end
end
