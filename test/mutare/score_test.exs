defmodule Mutare.ScoreTest do
  use ExUnit.Case, async: true

  alias Mutare.{Result, Score}

  doctest Mutare.Score

  test "score/1 = killed / (total - no_coverage)" do
    results = [
      %Result{status: :killed},
      %Result{status: :killed},
      %Result{status: :survived}
    ]

    assert Score.score(results) == 2 / 3 * 100
  end

  test "score/1 counts a timeout as a kill" do
    results = [
      %Result{status: :killed},
      %Result{status: :timeout},
      %Result{status: :survived}
    ]

    # 2 kills (killed + timeout) / 3 total
    assert Score.score(results) == 2 / 3 * 100
  end

  test "score/1 counts an atom-table exhaustion as a kill" do
    results = [
      %Result{status: :killed},
      %Result{status: :atom_exhausted},
      %Result{status: :survived}
    ]

    # 2 kills (killed + atom_exhausted) / 3 total — a divergence like a timeout.
    assert Score.score(results) == 2 / 3 * 100
  end

  test "score/1 excludes no_coverage from the denominator" do
    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :no_coverage}
    ]

    assert Score.score(results) == 50.0
  end

  test "score/1 excludes ignored from the denominator" do
    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :ignored}
    ]

    # 1 killed / (3 - 1 ignored) = 50%
    assert Score.score(results) == 50.0
  end

  test "score/1 excludes harness_error from the denominator (an infra failure is not a kill)" do
    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :harness_error}
    ]

    # 1 killed / (3 - 1 harness_error) = 50% — the harness error is neither a
    # kill nor part of the denominator.
    assert Score.score(results) == 50.0
  end

  test "score/1 is 100.0 when there is nothing to test" do
    assert Score.score([]) == 100.0
    assert Score.score([%Result{status: :no_coverage}]) == 100.0
  end

  test "score/1 excludes poisoned from the denominator" do
    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :poisoned}
    ]

    # 1 killed / (3 - 1 poisoned) = 50% — poisoned is dropped, not a kill.
    assert Score.score(results) == 50.0
  end

  test "score/1 of a lone survivor is 0.0 (denominator of 1, not forced to 100)" do
    # Pins the `denominator <= 0` guard at its boundary: denom is 1 here, so the
    # real ratio is reported rather than the nothing-to-test 100.0.
    assert Score.score([%Result{status: :survived}]) == 0.0
  end

  describe "harness_error_rate/1" do
    test "is 0.0 when nothing ran" do
      assert Score.harness_error_rate([]) == 0.0

      # no_coverage/ignored/poisoned never launched a run — not a denominator.
      assert Score.harness_error_rate([
               %Result{status: :no_coverage},
               %Result{status: :ignored},
               %Result{status: :poisoned}
             ]) == 0.0
    end

    test "is the fraction of the mutants that *ran* which harness-errored" do
      results = [
        %Result{status: :killed},
        %Result{status: :survived},
        %Result{status: :timeout},
        %Result{status: :atom_exhausted},
        %Result{status: :harness_error}
      ]

      # 1 harness error / 5 that ran — an atom-table crash reached a verdict too.
      assert Score.harness_error_rate(results) == 0.2
    end

    test "excludes skipped statuses from the denominator (measures broken running, not skips)" do
      results = [
        %Result{status: :harness_error},
        %Result{status: :killed},
        # These never ran, so they must not dilute the rate.
        %Result{status: :no_coverage},
        %Result{status: :ignored},
        %Result{status: :poisoned}
      ]

      # 1 harness error / 2 that ran (harness_error + killed) = 0.5, not 1/5.
      assert Score.harness_error_rate(results) == 0.5
    end
  end

  describe "harness_errors_exceed?/2" do
    defp half_errored do
      [%Result{status: :harness_error}, %Result{status: :killed}]
    end

    test "a nil threshold disables the check" do
      refute Score.harness_errors_exceed?(half_errored(), nil)
    end

    test "true only strictly above the threshold (the boundary does not abort)" do
      # rate is 0.5
      refute Score.harness_errors_exceed?(half_errored(), 0.5)
      refute Score.harness_errors_exceed?(half_errored(), 0.6)
      assert Score.harness_errors_exceed?(half_errored(), 0.4)
    end

    test "is false when nothing ran (no false abort on an all-skipped run)" do
      refute Score.harness_errors_exceed?([%Result{status: :no_coverage}], 0.0)
    end
  end

  describe "passes_gate?/2" do
    defp gate_results(killed, survived) do
      List.duplicate(%Result{status: :killed}, killed) ++
        List.duplicate(%Result{status: :survived}, survived)
    end

    test "a nil minimum always passes" do
      assert Score.passes_gate?(gate_results(0, 3), nil)
    end

    test "passes when the score meets or exceeds the minimum (boundary included)" do
      assert Score.passes_gate?(gate_results(2, 2), 50.0)
      assert Score.passes_gate?(gate_results(3, 1), 50.0)
    end

    test "fails when the score is below the minimum" do
      refute Score.passes_gate?(gate_results(1, 3), 50.0)
    end
  end

  describe "gate_failures/2" do
    test "returns no failures when gates are disabled" do
      results = [
        %Result{status: :survived},
        %Result{status: :no_coverage},
        %Result{status: :poisoned},
        %Result{status: :harness_error}
      ]

      assert Score.gate_failures(results, []) == []
    end

    test "reports score and non-meaningful-result gate failures" do
      results = [
        %Result{status: :killed},
        %Result{status: :survived},
        %Result{status: :no_coverage},
        %Result{status: :no_coverage},
        %Result{status: :poisoned},
        %Result{status: :harness_error}
      ]

      assert Score.gate_failures(results,
               min_score: 75,
               max_no_coverage: 1,
               fail_on_poisoned: true,
               fail_on_harness_error: true
             ) == [
               "mutation score 50.0% is below the required minimum of 75.0%",
               "2 no-coverage mutants exceed the allowed maximum of 1",
               "1 poisoned mutant is present and --fail-on-poisoned is set",
               "1 harness-error mutant is present and --fail-on-harness-error is set"
             ]
    end

    test "treats max_no_coverage as an inclusive count boundary" do
      results = [%Result{status: :no_coverage}]

      assert Score.gate_failures(results, max_no_coverage: 1) == []

      assert Score.gate_failures(results, max_no_coverage: 0) == [
               "1 no-coverage mutant exceeds the allowed maximum of 0"
             ]
    end

    test "accepts an options map as well as a keyword list" do
      assert Score.gate_failures([%Result{status: :poisoned}], %{fail_on_poisoned: true}) == [
               "1 poisoned mutant is present and --fail-on-poisoned is set"
             ]
    end

    test "a map without a fail-on key defaults it off (no crash on the missing default)" do
      # `gate_opt/3`'s map clause must fall back to `false`, not `nil`, for an absent
      # key — a `nil` flag reaches no `fail_on_status_failure/4` clause and would crash.
      assert Score.gate_failures([%Result{status: :harness_error}], %{fail_on_poisoned: true}) ==
               []
    end

    test "no score failure when the score meets the minimum" do
      # A passing gate must produce nothing: the `unless passes_gate?(...)` guard has to
      # actually consult the score, not unconditionally emit a failure.
      assert Score.gate_failures([%Result{status: :killed}], min_score: 50) == []
    end

    test "an enabled fail-on flag with zero such mutants raises no failure" do
      # count is 0, so `fail_on_status_failure/4` must short-circuit — never emit a
      # spurious "0 poisoned mutants are present".
      assert Score.gate_failures([%Result{status: :killed}], fail_on_poisoned: true) == []
    end

    test "pluralises the fail-on wording for two or more mutants" do
      results = [%Result{status: :poisoned}, %Result{status: :poisoned}]

      assert Score.gate_failures(results, fail_on_poisoned: true) == [
               "2 poisoned mutants are present and --fail-on-poisoned is set"
             ]
    end
  end
end
