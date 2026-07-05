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
          output: String.t() | nil,
          exit_status: non_neg_integer() | nil
        }

  defstruct [:site, :status, :duration_ms, :output, :exit_status]

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
  Returns whether `status` counts as a killed mutant.

  `:killed`, `:timeout`, and `:atom_exhausted` count as kills.

  ## Examples

      iex> Mutare.Result.kill?(:killed)
      true
      iex> Mutare.Result.kill?(:survived)
      false
  """
  @spec kill?(status()) :: boolean()
  def kill?(status), do: status in @kill_statuses

  @doc """
  Returns whether `status` counts in the mutation-score denominator.

  `:no_coverage`, `:ignored`, `:poisoned`, and `:harness_error` are excluded
  because they do not produce a test-suite verdict for the mutation.

  ## Examples

      iex> Enum.filter(Mutare.Result.Status.names(), &Mutare.Result.scored?/1)
      [:killed, :timeout, :atom_exhausted, :survived]
  """
  @spec scored?(status()) :: boolean()
  def scored?(status), do: status not in @unscored_statuses

  @doc """
  Returns whether a mutant launched a test run.

  `:no_coverage`, `:ignored`, and `:poisoned` never start a test run.
  `:harness_error` does start one and is included here.

  ## Examples

      iex> Mutare.Result.ran?(:harness_error)
      true
      iex> Mutare.Result.ran?(:ignored)
      false
  """
  @spec ran?(status()) :: boolean()
  def ran?(status), do: status not in @unran_statuses
end
