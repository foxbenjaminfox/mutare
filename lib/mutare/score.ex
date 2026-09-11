defmodule Mutare.Score do
  @moduledoc """
  The mutation score and the CI gates computed over a run's results.

  The score is `killed / (total − no_coverage − ignored − poisoned − harness_error)`: a
  timeout or an atom-table exhaustion counts as a kill, and a mutant that reached no verdict
  is left out of the denominator. `Mutare.Result` classifies each status (`kill?/1`,
  `scored?/1`, `ran?/1`); this module only counts.

  The gates (`gate_failures/2`, `harness_errors_exceed?/2`) are policy over the same tallies:
  `:no_coverage`, `:poisoned`, and `:harness_error` stay out of the score, but a CI run can
  still fail on them. Rendering the tallies as text is `Mutare.Report`'s job.
  """

  alias Mutare.Result

  @doc """
  Mutation score as a percentage:
  `killed / (total − no_coverage − ignored − poisoned − harness_error)`.
  Returns `100.0` when the denominator is zero (nothing to test).

      iex> results = [
      ...>   %Mutare.Result{status: :killed},
      ...>   %Mutare.Result{status: :survived},
      ...>   %Mutare.Result{status: :no_coverage}
      ...> ]
      iex> Mutare.Score.score(results)
      50.0
  """
  @spec score([Result.t()]) :: float()
  def score(results) do
    # Kills (numerator) and the scored set (denominator) are classified by `Mutare.Result`:
    # a timeout/atom-exhaustion is a kill, while no-coverage/ignored/poisoned/harness-error
    # reach no verdict and are excluded from the denominator.
    counts = tally(results)
    killed = count_where(counts, &Result.kill?/1)
    denominator = count_where(counts, &Result.scored?/1)

    if denominator <= 0, do: 100.0, else: killed / denominator * 100
  end

  @doc """
  Format a percentage value (already on a 0..100 scale) to one decimal place,
  without a trailing `%`.

      iex> Mutare.Score.percent(2 / 3 * 100)
      "66.7"
  """
  @spec percent(number()) :: String.t()
  def percent(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  @doc """
  Returns whether `results` meet a minimum score percentage.

  A `nil` minimum always passes.

      iex> results = [%Mutare.Result{status: :killed}, %Mutare.Result{status: :survived}]
      iex> Mutare.Score.passes_gate?(results, 60)
      false
      iex> Mutare.Score.passes_gate?(results, nil)
      true
  """
  @spec passes_gate?([Result.t()], number() | nil) :: boolean()
  def passes_gate?(_results, nil), do: true
  def passes_gate?(results, min_score), do: score(results) >= min_score

  @doc """
  Human-readable failures for complete-run CI gates.

  These gates are separate from score semantics: `:no_coverage`, `:poisoned`,
  and `:harness_error` stay out of the mutation-score denominator, but a caller
  can still make them fatal for CI. `opts` may be a keyword list or an options
  map carrying:

    * `:min_score` — minimum mutation score percentage, or `nil`
    * `:max_no_coverage` — maximum allowed `:no_coverage` count, or `nil`
    * `:fail_on_poisoned` — fail if any mutant is `:poisoned`
    * `:fail_on_harness_error` — fail if any mutant is `:harness_error`
  """
  @spec gate_failures([Result.t()], keyword() | map()) :: [String.t()]
  def gate_failures(results, opts \\ []) do
    counts = tally(results)

    [
      score_gate_failure(results, gate_opt(opts, :min_score)),
      max_count_gate_failure(count(counts, :no_coverage), gate_opt(opts, :max_no_coverage)),
      fail_on_status_failure(
        count(counts, :poisoned),
        gate_opt(opts, :fail_on_poisoned, false),
        "poisoned",
        "--fail-on-poisoned"
      ),
      fail_on_status_failure(
        count(counts, :harness_error),
        gate_opt(opts, :fail_on_harness_error, false),
        "harness-error",
        "--fail-on-harness-error"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Fraction of launched mutant runs that ended in `:harness_error`.

  The denominator includes `:killed`, `:survived`, `:timeout`,
  `:atom_exhausted`, and `:harness_error`. It excludes `:no_coverage`,
  `:ignored`, and `:poisoned`, which never launch a test run. Returns `0.0`
  when nothing ran.

      iex> results = [
      ...>   %Mutare.Result{status: :killed},
      ...>   %Mutare.Result{status: :harness_error},
      ...>   %Mutare.Result{status: :no_coverage}
      ...> ]
      iex> Mutare.Score.harness_error_rate(results)
      0.5
  """
  @spec harness_error_rate([Result.t()]) :: float()
  def harness_error_rate(results) do
    counts = tally(results)
    errors = count(counts, :harness_error)
    ran = count_where(counts, &Result.ran?/1)

    if ran == 0, do: 0.0, else: errors / ran
  end

  @doc """
  Returns whether `harness_error_rate/1` exceeds `max_rate`.

  `max_rate` is a fraction from `0.0` to `1.0`. A `nil` value disables the
  check and returns `false`.
  """
  @spec harness_errors_exceed?([Result.t()], number() | nil) :: boolean()
  # Equivalent mutant: dropping this clause changes nothing. The fallback clause
  # would then compute `harness_error_rate(results) > nil`, and a number always
  # sorts before `nil` in Erlang term order, so the result is `false` for a nil
  # `max_rate` either way. Unkillable — scoped to the clause-drop so the
  # `false -> true` literal sibling (killed by the nil test) still counts.
  # mutare:ignore[clause_drop] falls through to the same false for a nil max_rate
  def harness_errors_exceed?(_results, nil), do: false
  def harness_errors_exceed?(results, max_rate), do: harness_error_rate(results) > max_rate

  # --- internals -----------------------------------------------------------

  defp tally(results), do: Enum.frequencies_by(results, & &1.status)

  defp gate_opt(opts, key, default \\ nil)
  defp gate_opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  # Equivalent mutant: `opts` is always a keyword list or a map (per `gate_failures/2`'s
  # spec), and the `is_list` clause above already claimed every list — so this last clause
  # only ever runs for maps, whether or not its `is_map` guard remains. Scoped to
  # `[guard_drop]` so the `default` drop (a real map-default path) stays killable.
  # mutare:ignore[guard_drop] opts is always keyword|map; the is_list clause owns lists
  defp gate_opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)

  # Equivalent mutant: dropping this clause changes nothing. A nil `min_score` then
  # reaches the general clause, where `passes_gate?(results, nil)` is true (a nil minimum
  # always passes), so `unless true` yields nil either way. Scoped to the clause-drop so
  # the `unless` condition mutant on the general clause stays killable.
  # mutare:ignore[clause_drop] passes_gate?(_, nil) is true, so the general clause also returns nil
  defp score_gate_failure(_results, nil), do: nil

  defp score_gate_failure(results, min_score) do
    unless passes_gate?(results, min_score) do
      "mutation score #{percent(score(results))}% is below the required minimum of #{percent(min_score)}%"
    end
  end

  # Equivalent mutant: dropping this clause changes nothing. A nil `max` then reaches the
  # `n <= max` clause, and a number always sorts before an atom in Erlang term order, so
  # `n <= nil` is true and it returns nil either way. Scoped to the clause-drop so the
  # `n <= max` boundary guard stays killable.
  # mutare:ignore[clause_drop] n <= nil is always true, so the guarded clause also returns nil
  defp max_count_gate_failure(_n, nil), do: nil
  defp max_count_gate_failure(n, max) when n <= max, do: nil

  defp max_count_gate_failure(n, max) do
    "#{n} no-coverage mutant#{plural(n)} #{exceed(n)} the allowed maximum of #{max}"
  end

  defp fail_on_status_failure(0, _enabled, _label, _flag), do: nil
  defp fail_on_status_failure(_n, false, _label, _flag), do: nil

  defp fail_on_status_failure(n, true, label, flag) do
    "#{n} #{label} mutant#{plural(n)} #{present(n)} and #{flag} is set"
  end

  defp count(counts, status), do: Map.get(counts, status, 0)

  # Sum a frequency map's values over the statuses a predicate admits.
  defp count_where(counts, pred) do
    for {status, n} <- counts, pred.(status), reduce: 0, do: (acc -> acc + n)
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp exceed(1), do: "exceeds"
  defp exceed(_), do: "exceed"

  defp present(1), do: "is present"
  defp present(_), do: "are present"
end
