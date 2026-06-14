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
    {_meta, sites} = Mutare.transform_string(@source, file: "lib/billing.ex")
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

  test "score/1 excludes no_coverage from the denominator" do
    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :no_coverage}
    ]

    assert Report.score(results) == 50.0
  end

  test "score/1 is 100.0 when there is nothing to test" do
    assert Report.score([]) == 100.0
    assert Report.score([%Result{status: :no_coverage}]) == 100.0
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
