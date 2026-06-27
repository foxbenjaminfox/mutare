defmodule Mutare.Result do
  @moduledoc "The outcome of running the suite against one mutant."

  alias Mutare.Site

  @type status ::
          :killed
          | :survived
          | :no_coverage
          | :timeout
          | :atom_exhausted
          | :ignored
          | :poisoned
          | :harness_error

  @type t :: %__MODULE__{
          site: Site.t(),
          status: status(),
          duration_ms: non_neg_integer() | nil,
          output: String.t() | nil
        }

  defstruct [:site, :status, :duration_ms, :output]

  # --- status classification -------------------------------------------------
  # The single home for the scoring semantics the reporters and the runner share (see
  # CLAUDE.md "Result statuses"). Centralised here so a new status is classified once,
  # not re-listed inline in `Mutare.Report`'s score and harness-rate computations.
  #
  # The three sets are *derived* from the `Mutare.Result.Status` descriptor registry
  # (the single source of every per-status fact) so adding a status — a row there plus
  # the `@type status` union above — classifies it without a second list to keep in
  # sync. The `in`-list form is preserved (a non-status atom answers `false`/`true`
  # rather than raising), so these predicates' contract is unchanged.

  @kill_statuses Mutare.Result.Status.where(:kill?)
  @unscored_statuses Enum.reject(
                       Mutare.Result.Status.names(),
                       &Mutare.Result.Status.fetch!(&1).scored?
                     )
  @unran_statuses Enum.reject(Mutare.Result.Status.names(), &Mutare.Result.Status.fetch!(&1).ran?)

  @doc """
  A detected mutant — counted in the score *numerator*: `:killed` outright, or a
  resource-divergence the suite still caught (`:timeout`, a hang; `:atom_exhausted`,
  unbounded atoms that crashed the VM).
  """
  @spec kill?(status()) :: boolean()
  def kill?(status), do: status in @kill_statuses

  @doc """
  Counted in the score *denominator*. False for the four statuses that reached no verdict
  about the mutation — `:no_coverage` (no test ran the line), `:ignored` (`# mutare:ignore`),
  `:poisoned` (wouldn't compile), `:harness_error` (the run itself failed) — so the score
  measures only mutations the suite actually exercised.
  """
  @spec scored?(status()) :: boolean()
  def scored?(status), do: status not in @unscored_statuses

  @doc """
  Whether a mutant's run actually launched a `mix test` (reached, or tried to reach, a
  verdict). True for everything except `:no_coverage`/`:ignored`/`:poisoned`, which never
  started one. The denominator of `Mutare.Report.harness_error_rate/1` — unlike `scored?/1`
  it *includes* `:harness_error` (a run that launched but failed).
  """
  @spec ran?(status()) :: boolean()
  def ran?(status), do: status not in @unran_statuses
end
