defmodule Mutare.ReportTest do
  use ExUnit.Case, async: true

  alias Mutare.{Report, Result}

  @source """
  defmodule Billing do
    def ok?(total, threshold) do
      total >= threshold
    end
  end
  """

  defp site(op_to) do
    {_meta, sites, _next_id} = Mutare.transform_string(@source, file: "lib/billing.ex")
    Enum.find(sites, &(&1.original_op == :>= and &1.mutated_op == op_to))
  end

  test "diff/2 patches the original at the site range, leaving the line otherwise intact" do
    assert Report.diff(site(:>), @source) ==
             "-    total >= threshold\n+    total > threshold"
  end

  test "header/1 reads file:line and mutator metadata" do
    assert Report.header(site(:>)) == "lib/billing.ex:3  [relational, in-place]  SURVIVED"
  end

  test "score/1 = killed / (total - no_coverage)" do
    results = [
      %Result{status: :killed},
      %Result{status: :killed},
      %Result{status: :survived}
    ]

    assert Report.score(results) == 2 / 3 * 100
  end

  test "score/1 counts a timeout as a kill" do
    results = [
      %Result{status: :killed},
      %Result{status: :timeout},
      %Result{status: :survived}
    ]

    # 2 kills (killed + timeout) / 3 total
    assert Report.score(results) == 2 / 3 * 100
  end

  test "summary/1 surfaces timeouts when present" do
    results = [%Result{status: :killed}, %Result{status: :timeout}, %Result{status: :survived}]

    assert Report.summary(results) ==
             "mutation score: 66.7%  (1 killed, 1 timeout, 1 survived, 3 total)"
  end

  test "score/1 excludes no_coverage from the denominator" do
    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :no_coverage}
    ]

    assert Report.score(results) == 50.0
  end

  test "score/1 excludes ignored from the denominator" do
    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :ignored}
    ]

    # 1 killed / (3 - 1 ignored) = 50%
    assert Report.score(results) == 50.0
  end

  test "summary/1 surfaces ignored when present" do
    results = [%Result{status: :killed}, %Result{status: :survived}, %Result{status: :ignored}]
    assert Report.summary(results) =~ "1 ignored"
  end

  test "score/1 excludes harness_error from the denominator (an infra failure is not a kill)" do
    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :harness_error}
    ]

    # 1 killed / (3 - 1 harness_error) = 50% — the harness error is neither a
    # kill nor part of the denominator.
    assert Report.score(results) == 50.0
  end

  test "summary/1 surfaces harness errors only when present" do
    refute Report.summary([%Result{status: :killed}]) =~ "harness-error"

    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :harness_error}
    ]

    assert Report.summary(results) ==
             "mutation score: 50.0%  (1 killed, 1 survived, 1 harness-error, 3 total)"
  end

  test "score/1 is 100.0 when there is nothing to test" do
    assert Report.score([]) == 100.0
    assert Report.score([%Result{status: :no_coverage}]) == 100.0
  end

  test "summary/1 includes a no-coverage count only when present" do
    refute Report.summary([%Result{status: :killed}]) =~ "no-coverage"

    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :no_coverage}
    ]

    assert Report.summary(results) ==
             "mutation score: 50.0%  (1 killed, 1 survived, 1 no-coverage, 3 total)"
  end

  describe "harness_error_rate/1" do
    test "is 0.0 when nothing ran" do
      assert Report.harness_error_rate([]) == 0.0

      # no_coverage/ignored/poisoned never launched a run — not a denominator.
      assert Report.harness_error_rate([
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
        %Result{status: :harness_error}
      ]

      # 1 harness error / 4 that ran.
      assert Report.harness_error_rate(results) == 0.25
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
      assert Report.harness_error_rate(results) == 0.5
    end
  end

  describe "harness_errors_exceed?/2" do
    defp half_errored do
      [%Result{status: :harness_error}, %Result{status: :killed}]
    end

    test "a nil threshold disables the check" do
      refute Report.harness_errors_exceed?(half_errored(), nil)
    end

    test "true only strictly above the threshold (the boundary does not abort)" do
      # rate is 0.5
      refute Report.harness_errors_exceed?(half_errored(), 0.5)
      refute Report.harness_errors_exceed?(half_errored(), 0.6)
      assert Report.harness_errors_exceed?(half_errored(), 0.4)
    end

    test "is false when nothing ran (no false abort on an all-skipped run)" do
      refute Report.harness_errors_exceed?([%Result{status: :no_coverage}], 0.0)
    end
  end

  describe "passes_gate?/2" do
    defp gate_results(killed, survived) do
      List.duplicate(%Result{status: :killed}, killed) ++
        List.duplicate(%Result{status: :survived}, survived)
    end

    test "a nil minimum always passes" do
      assert Report.passes_gate?(gate_results(0, 3), nil)
    end

    test "passes when the score meets or exceeds the minimum (boundary included)" do
      assert Report.passes_gate?(gate_results(2, 2), 50.0)
      assert Report.passes_gate?(gate_results(3, 1), 50.0)
    end

    test "fails when the score is below the minimum" do
      refute Report.passes_gate?(gate_results(1, 3), 50.0)
    end
  end

  test "render/2 lists survivors as diffs plus a summary line" do
    sites = [site(:>), site(:<=)]
    sources = %{"lib/billing.ex" => @source}

    results = [
      %Result{site: Enum.at(sites, 0), status: :survived},
      %Result{site: Enum.at(sites, 1), status: :killed}
    ]

    out = Report.render(results, sources)

    assert out =~ "lib/billing.ex:3  [relational, in-place]  SURVIVED"
    assert out =~ "-    total >= threshold\n+    total > threshold"
    assert out =~ "mutation score: 50.0%  (1 killed, 1 survived, 2 total)"
  end
end
