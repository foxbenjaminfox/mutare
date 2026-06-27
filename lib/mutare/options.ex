defmodule Mutare.Options do
  @moduledoc """
  Validated **configuration** for a mutation run — the struct `Mutare.run/2` accepts.

  `new/1` resolves a keyword list (or another `Options`) into a struct,
  validating every field up front so a bad `:workers`, `:timeout`,
  `:test_selection`, `:paths`, and so on fails loudly with an `ArgumentError`
  rather than misbehaving deep in the run. Passing the same options on the
  command line or in `.mutare.exs` goes through the same validation — see
  `mix help mutare` for the full list of settable keys and their defaults.

  Every option's default, CLI passthrough shape, `--show-config` visibility, and
  validator live in one place — `Mutare.Options.Registry` — which this module
  derives its `defstruct`, `@keys`, and `new/1` from. Adding an option is a single
  registry entry.

  Runtime *wiring* (the resolved `Mutare.Project` and the live-progress hooks) is
  **not** configuration and does not live here — see `Mutare.Run.Context`.

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
  Resolve and validate options.

  Accepts a keyword list (typically `Mutare.Config.merge/2`'s output, plus
  `:only_files`) or an existing `Options` (re-normalized and revalidated). Raises
  `ArgumentError` on an unknown key or an invalid value. `:workers` defaults to
  `System.schedulers_online/0`, resolved here so the struct always carries a
  concrete positive integer.

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
    |> new()
  end

  def new(opts) when is_list(opts) do
    reject_unknown!(opts)

    Registry.specs()
    |> Enum.map(fn %{key: key, validate: validate} -> {key, validate.(opt(opts, key))} end)
    |> then(&struct(__MODULE__, &1))
  end

  # Read option `key` from `opts`, falling back to its registry default — the one place `new/1`'s
  # defaults come from, so they can't drift from `defstruct`'s. (`:workers`'s `nil` default is
  # resolved to `System.schedulers_online/0` inside its validator, the lone computed default.)
  defp opt(opts, key), do: Keyword.get(opts, key, Keyword.fetch!(@field_defaults, key))

  defp reject_unknown!(opts) do
    case Enum.uniq(Keyword.keys(opts)) -- @keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "unknown option(s) #{inspect(unknown)}; valid: #{inspect(@keys)}"
    end
  end
end
