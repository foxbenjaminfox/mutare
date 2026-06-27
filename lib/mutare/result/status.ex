defmodule Mutare.Result.Status do
  @moduledoc """
  The single descriptor registry for the `Mutare.Result` status vocabulary.

  A result status carries the same handful of facts at every surface that touches
  it: is it a kill (score *numerator*), is it scored (in the *denominator*), did it
  *run* (launched a `mix test`), what is its mutation-testing-elements / Stryker
  name, how is it labelled in the one-line `Mutare.Report.summary/1` and the live
  counter, does it leave a permanent line behind in `Mutare.Report.Live` (and how
  `--verbose` labels its always-emitted line). Those
  facts used to be re-listed inline in *five* places — `Mutare.Result`
  (classification lists), `Mutare.Report` (the summary tally), `Mutare.Report.Json`
  (the schema map), and `Mutare.Report.Live` (`@leave_behind` + the counter extras)
  — which drift apart silently when a status is added (see CLAUDE.md "Result
  statuses"). They live here once: one descriptor map per status, ordered as the
  summary/counter render them, the consumers reading fields off `all/0`/`fetch!/1`
  rather than re-enumerating the vocabulary.

  Adding a status is two edits — a row here and the `@type status` union in
  `Mutare.Result` — and `Mutare.Result.StatusTest` pins the registry to that type so
  the two cannot diverge unnoticed. A descriptor is a plain map (a struct can't be
  built in its own module's compile-time attributes), but the rows are validated at
  compile time against the schema below, so a missing required key or a typo'd field
  name fails the build rather than silently producing a wrong descriptor.

  Per-field defaults are chosen so a row states only what is *unusual* about a
  status: a status is `scored?`/`ran?` and not a `kill?` unless it says otherwise
  (the common in-the-denominator, reached-a-verdict, didn't-detect shape), and it is
  not pinned into the summary nor surfaced as a live extra/leave-behind unless it
  opts in.
  """

  @typedoc "An `IO.ANSI` colour name for a leave-behind label."
  @type colour :: atom()

  @type t :: %{
          name: Mutare.Result.status(),
          kill?: boolean(),
          scored?: boolean(),
          ran?: boolean(),
          json: String.t(),
          summary_label: String.t(),
          always_in_summary?: boolean(),
          extra_label: String.t() | nil,
          leave_behind: {String.t(), colour()} | nil,
          verbose_label: {String.t(), colour()}
        }

  # The descriptor schema. `@required` have no default (every row must state them);
  # `@defaults` are the common-case values a row overrides only when unusual.
  # `:verbose_label` is required (not defaulted) because `--verbose` leaves a line
  # behind for *every* status, so each must carry one — unlike `:leave_behind`,
  # which only the survivors/problems opt into.
  @required [:name, :json, :summary_label, :verbose_label]
  @defaults %{
    # Score numerator: a detected mutant.
    kill?: false,
    # Score denominator: the suite actually exercised the mutation.
    scored?: true,
    # Launched (or tried to launch) a `mix test` — the harness-error-rate denominator.
    ran?: true,
    # Pinned into `summary/1` even at a count of zero (`:killed`/`:survived`).
    always_in_summary?: false,
    # Only-when-nonzero counter tail of the live block; nil ⇒ not shown there
    # (`:killed`/`:survived` own the counter headline instead).
    extra_label: nil,
    # `{label, colour}` permanent scrollback line, or nil for a status that only
    # moves the counter.
    leave_behind: nil
  }
  @known @required ++ Map.keys(@defaults)

  # The vocabulary, ordered exactly as `Mutare.Report.summary/1` lists it (and as the
  # live counter's extras tail follows once `:killed`/`:survived` — the headline slots
  # — are filtered out). Classification (`kill?`/`scored?`/`ran?`) reproduces the
  # original `Mutare.Result` constant lists; `json` the `Mutare.Report.Json` map;
  # `leave_behind`/`extra_label` the `Mutare.Report.Live` styling.
  @rows [
    %{
      name: :killed,
      kill?: true,
      json: "Killed",
      summary_label: "killed",
      always_in_summary?: true,
      verbose_label: {"KILLED", :green}
    },
    %{
      name: :timeout,
      kill?: true,
      json: "Timeout",
      summary_label: "timeout",
      extra_label: "timeout",
      leave_behind: {"TIMEOUT", :yellow},
      verbose_label: {"TIMEOUT", :yellow}
    },
    # No dedicated schema status for an atom-table crash: it is a detected
    # resource-divergence, so it maps to "Timeout" (the schema's other
    # "detected-by-non-completion" status) — score-consistent with Stryker.
    %{
      name: :atom_exhausted,
      kill?: true,
      json: "Timeout",
      summary_label: "atom-table",
      extra_label: "atom-table",
      leave_behind: {"ATOMS", :yellow},
      verbose_label: {"ATOMS", :yellow}
    },
    %{
      name: :survived,
      json: "Survived",
      summary_label: "survived",
      always_in_summary?: true,
      leave_behind: {"SURVIVED", :red},
      verbose_label: {"SURVIVED", :red}
    },
    %{
      name: :no_coverage,
      scored?: false,
      ran?: false,
      json: "NoCoverage",
      summary_label: "no-coverage",
      extra_label: "no-coverage",
      verbose_label: {"NOCOV", :cyan}
    },
    %{
      name: :ignored,
      scored?: false,
      ran?: false,
      json: "Ignored",
      summary_label: "ignored",
      extra_label: "ignored",
      verbose_label: {"IGNORED", :light_black}
    },
    %{
      name: :poisoned,
      scored?: false,
      ran?: false,
      json: "CompileError",
      summary_label: "poisoned",
      extra_label: "poisoned",
      verbose_label: {"POISON", :blue}
    },
    # Reached no verdict but *did* run (the harness-error-rate denominator includes
    # it), so `ran?` keeps its default `true` while `scored?` is false.
    %{
      name: :harness_error,
      scored?: false,
      json: "RuntimeError",
      summary_label: "harness-error",
      extra_label: "errors",
      leave_behind: {"ERROR", :magenta},
      verbose_label: {"ERROR", :magenta}
    }
  ]

  # Validate-and-default each row at compile time: an unknown or missing key fails the
  # build, so a typo can't slip a malformed descriptor past the registry.
  @descriptors Enum.map(@rows, fn row ->
                 unknown = Map.keys(row) -- @known

                 unknown == [] ||
                   raise ArgumentError, "unknown status descriptor key(s): #{inspect(unknown)}"

                 missing = @required -- Map.keys(row)

                 missing == [] ||
                   raise ArgumentError,
                         "status #{inspect(row[:name])} missing key(s): #{inspect(missing)}"

                 Map.merge(@defaults, row)
               end)

  @by_name Map.new(@descriptors, &{&1.name, &1})

  @doc "Every status descriptor, in summary/counter render order."
  @spec all :: [t()]
  def all, do: @descriptors

  @doc "Every status name, in render order."
  @spec names :: [Mutare.Result.status()]
  def names, do: Enum.map(@descriptors, & &1.name)

  @doc """
  The descriptor for `status`, raising on an unregistered name. Loud by design — the
  same fail-fast a missing `Map.fetch!` key gave the JSON map: a status with no row
  is a bug, surfaced rather than silently rendered blank.
  """
  @spec fetch!(Mutare.Result.status()) :: t()
  def fetch!(status), do: Map.fetch!(@by_name, status)

  @doc "The descriptor for `status`, or `nil` for an unregistered name."
  @spec get(atom()) :: t() | nil
  def get(status), do: Map.get(@by_name, status)

  @doc "The status names whose descriptor field `field` is truthy, in render order."
  @spec where(atom()) :: [Mutare.Result.status()]
  def where(field) when is_atom(field) do
    for d <- @descriptors, Map.fetch!(d, field), do: d.name
  end
end
