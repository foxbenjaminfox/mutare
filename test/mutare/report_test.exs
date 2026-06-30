defmodule Mutare.ReportTest do
  use ExUnit.Case, async: true

  alias Mutare.{Report, Result, Site}

  doctest Mutare.Report

  @source """
  defmodule Billing do
    def ok?(total, threshold) do
      total >= threshold
    end
  end
  """

  # A multi-line clause, for exercising the clause-drop (delete) diff path.
  @drop_source """
  defmodule M do
    def f(0) do
      :z
    end

    def f(_), do: :o
  end
  """

  # A clause-drop site over `def f(0) do ... end` (lines 2..4 of @drop_source).
  defp drop_site do
    range = %{start: [line: 2, column: 3], end: [line: 4, column: 8]}
    Site.clause_drop(1, "m.ex", range, Sourceror.parse_string!("def f(0) do\n  :z\nend"))
  end

  defp site(op_to) do
    {_meta, sites, _next_id} = Mutare.transform_string(@source, file: "lib/billing.ex")
    Enum.find(sites, &(&1.original_form == :>= and &1.mutated_form == op_to))
  end

  test "diff/2 patches the original at the site range, leaving the line otherwise intact" do
    assert Report.diff(site(:>), @source) ==
             "-    total >= threshold\n+    total > threshold"
  end

  test "header/1 reads file:line and mutator metadata" do
    assert Report.header(site(:>)) == "lib/billing.ex:3  [relational, in-place]  SURVIVED"
  end

  test "header/1 labels a lifted mutant as lifted" do
    assert Report.header(drop_site()) == "m.ex:2  [clause_drop, lifted]  SURVIVED"
  end

  test "diff/2 of a clause-drop shows every line of the clause as a deletion" do
    assert Report.diff(drop_site(), @drop_source) ==
             "-  def f(0) do\n-    :z\n-  end"
  end

  # Regression: a call-final keyword argument (`String.split(x, trim: true)`) used
  # to render corrupt survivor diffs — the boolean value's range was one column too
  # wide (Sourceror counts a phantom colon for bare `true`/`false`/`nil`), eating the
  # closing paren; and a keyword *key* rendered as a bare atom (`:mutare`), breaking
  # keyword syntax. See `Mutare.Transform.NodeRange` and `Mutare.Site`.
  describe "diff/2 of a call-final keyword argument" do
    # `String.split/3` (pattern + options) — the shape from `ignore.ex` that first
    # surfaced this. (`String.split/2` would read `trim: true` *as* the pattern.)
    @kw_source """
    defmodule M do
      def f(x), do: String.split(x, ",", trim: true)
    end
    """

    defp kw_site(mutator, original_code) do
      {_meta, sites, _next} = Mutare.transform_string(@kw_source, mutators: [mutator])
      Enum.find(sites, &(&1.original_code == original_code))
    end

    test "a boolean value swap keeps the closing paren (true/false range is not over-wide)" do
      assert Report.diff(kw_site(Mutare.Mutators.Literal, "true"), @kw_source) ==
               "-  def f(x), do: String.split(x, \",\", trim: true)\n" <>
                 "+  def f(x), do: String.split(x, \",\", trim: false)"
    end

    test "a keyword-key swap renders in keyword form (`mutare:`, not `:mutare`)" do
      assert Report.diff(kw_site(Mutare.Mutators.AtomLiteral, "trim:"), @kw_source) ==
               "-  def f(x), do: String.split(x, \",\", trim: true)\n" <>
                 "+  def f(x), do: String.split(x, \",\", mutare: true)"
    end

    test "both patched diffs re-parse as valid Elixir" do
      for {mutator, original} <- [
            {Mutare.Mutators.Literal, "true"},
            {Mutare.Mutators.AtomLiteral, "trim:"}
          ] do
        patched = Report.patch(kw_site(mutator, original), @kw_source)
        assert {:ok, _} = Code.string_to_quoted(patched)
      end
    end
  end

  # Regression: a `~r/…/` sigil whose body escapes the closing delimiter (`\/`)
  # used to render a survivor with **no visible diff** — Sourceror's range ended
  # one column short (the `\/` is stored as `/`), and when the mutation only drops
  # a trailing flag (`~r/…/u` → `~r/…/`) the patch landed exactly on the dropped
  # `u`, leaving the line byte-identical. See `Mutare.Transform.NodeRange`.
  describe "diff/2 of a regex sigil with an escaped delimiter" do
    @rx_source ~S"""
    defmodule M do
      def f(name), do: String.replace(name, ~r/[\/:]/u, "-")
    end
    """

    defp rx_site(mutated_code) do
      {_meta, sites, _next} =
        Mutare.transform_string(@rx_source, mutators: [Mutare.Mutators.RegexLiteral])

      Enum.find(sites, &(&1.mutated_code == mutated_code))
    end

    test "dropping the /u flag changes the rendered line (not an empty diff)" do
      assert Report.diff(rx_site(~S{~r/[\/:]/}), @rx_source) ==
               ~S|-  def f(name), do: String.replace(name, ~r/[\/:]/u, "-")| <>
                 "\n" <> ~S|+  def f(name), do: String.replace(name, ~r/[\/:]/, "-")|
    end

    test "a whole-pattern swap replaces the sigil, keeping the trailing args intact" do
      assert Report.diff(rx_site(~S{~r/mutare/u}), @rx_source) ==
               ~S|-  def f(name), do: String.replace(name, ~r/[\/:]/u, "-")| <>
                 "\n" <> ~S|+  def f(name), do: String.replace(name, ~r/mutare/u, "-")|
    end

    test "every regex mutant's patch re-parses as valid Elixir" do
      {_meta, sites, _next} =
        Mutare.transform_string(@rx_source, mutators: [Mutare.Mutators.RegexLiteral])

      for site <- sites do
        assert {:ok, _} = Code.string_to_quoted(Report.patch(site, @rx_source))
      end
    end
  end

  # Regression: a multi-line `:replace` that removes (or adds) a line in the middle
  # of the fragment — the shape an Ecto `:hosted` mutation produces when it drops one
  # `where:` from a big `from` block. A naive line-by-line pairing re-emits every line
  # after the removal as a spurious delete+insert (they "shift" up past the gap); the
  # line-based (Myers) diff aligns the unchanged tail and shows only the dropped line.
  describe "diff/2 of a multi-line fragment with a removed line (the Ecto where-drop shape)" do
    @ml_source """
    defmodule M do
      def opts do
        from(u in User,
          where: u.active == true,
          where: u.age > 18,
          select: u
        )
      end
    end
    """

    # A site over the multi-line `from(...)` call (with its real Sourceror range and
    # rendering), whose mutation drops the middle `where:` line.
    defp where_drop_site do
      node =
        @ml_source
        |> Sourceror.parse_string!()
        |> Macro.prewalk([], fn
          {:from, _, _} = n, acc -> {n, [n | acc]}
          other, acc -> {other, acc}
        end)
        |> elem(1)
        |> List.first()

      range = Sourceror.get_range(node)
      {:from, meta, [first, kw]} = node

      kw2 =
        Enum.reject(kw, fn
          {{:__block__, _, [:where]}, v} -> Macro.to_string(v) =~ "18"
          _ -> false
        end)

      mutated = {:from, meta, [first, kw2]}

      %Site{
        range: range,
        operation: :replace,
        mutator: :ecto,
        kind: :in_place,
        file: "lib/m.ex",
        line: range.start[:line],
        column: range.start[:column],
        original_code: Sourceror.to_string(node),
        mutated_code: Sourceror.to_string(mutated)
      }
    end

    test "shows only the removed line as a deletion, the rest as ` ` context" do
      assert Report.diff(where_drop_site(), @ml_source) ==
               "     from(u in User,\n" <>
                 "       where: u.active == true,\n" <>
                 "-      where: u.age > 18,\n" <>
                 "       select: u\n" <>
                 "     )"
    end

    test "the patched diff re-parses as valid Elixir" do
      assert {:ok, _} = Code.string_to_quoted(Report.patch(where_drop_site(), @ml_source))
    end
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

  test "score/1 counts an atom-table exhaustion as a kill" do
    results = [
      %Result{status: :killed},
      %Result{status: :atom_exhausted},
      %Result{status: :survived}
    ]

    # 2 kills (killed + atom_exhausted) / 3 total — a divergence like a timeout.
    assert Report.score(results) == 2 / 3 * 100
  end

  test "summary/1 surfaces atom-table exhaustions when present" do
    results = [
      %Result{status: :killed},
      %Result{status: :atom_exhausted},
      %Result{status: :survived}
    ]

    assert Report.summary(results) ==
             "mutation score: 66.7%  (1 killed, 1 atom-table, 1 survived, 3 total)"
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

  test "score/1 excludes poisoned from the denominator" do
    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :poisoned}
    ]

    # 1 killed / (3 - 1 poisoned) = 50% — poisoned is dropped, not a kill.
    assert Report.score(results) == 50.0
  end

  test "score/1 of a lone survivor is 0.0 (denominator of 1, not forced to 100)" do
    # Pins the `denominator <= 0` guard at its boundary: denom is 1 here, so the
    # real ratio is reported rather than the nothing-to-test 100.0.
    assert Report.score([%Result{status: :survived}]) == 0.0
  end

  test "summary/1 surfaces poisoned only when present" do
    refute Report.summary([%Result{status: :killed}]) =~ "poisoned"

    results = [
      %Result{status: :killed},
      %Result{status: :survived},
      %Result{status: :poisoned}
    ]

    assert Report.summary(results) ==
             "mutation score: 50.0%  (1 killed, 1 survived, 1 poisoned, 3 total)"
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
        %Result{status: :atom_exhausted},
        %Result{status: :harness_error}
      ]

      # 1 harness error / 5 that ran — an atom-table crash reached a verdict too.
      assert Report.harness_error_rate(results) == 0.2
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

  describe "gate_failures/2" do
    test "returns no failures when gates are disabled" do
      results = [
        %Result{status: :survived},
        %Result{status: :no_coverage},
        %Result{status: :poisoned},
        %Result{status: :harness_error}
      ]

      assert Report.gate_failures(results, []) == []
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

      assert Report.gate_failures(results,
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

      assert Report.gate_failures(results, max_no_coverage: 1) == []

      assert Report.gate_failures(results, max_no_coverage: 0) == [
               "1 no-coverage mutant exceeds the allowed maximum of 0"
             ]
    end

    test "accepts an options map as well as a keyword list" do
      assert Report.gate_failures([%Result{status: :poisoned}], %{fail_on_poisoned: true}) == [
               "1 poisoned mutant is present and --fail-on-poisoned is set"
             ]
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

  test "render/2 with no survivors is just the summary (no leading blank lines)" do
    results = [%Result{site: site(:>), status: :killed}]
    assert Report.render(results, %{"lib/billing.ex" => @source}) == Report.summary(results)
  end

  test "render/2 includes only survivors, not killed mutants" do
    sites = [site(:>), site(:<=)]
    sources = %{"lib/billing.ex" => @source}

    results = [
      %Result{site: Enum.at(sites, 0), status: :survived},
      %Result{site: Enum.at(sites, 1), status: :killed}
    ]

    out = Report.render(results, sources)

    # the survivor (>= -> >) is shown; the killed mutant (>= -> <=) is not
    assert out =~ "+    total > threshold"
    refute out =~ "total <= threshold"
  end

  test "survivor/2 joins the header and diff with a single newline" do
    assert Report.survivor(site(:>), @source) ==
             "lib/billing.ex:3  [relational, in-place]  SURVIVED\n" <>
               "-    total >= threshold\n+    total > threshold"
  end

  test "ignored/1 renders file:line, mutator, and a reason when present" do
    with_reason = %Site{
      file: "lib/x.ex",
      line: 9,
      mutator: :arithmetic,
      ignore_reason: "deliberate"
    }

    without = %Site{file: "lib/x.ex", line: 9, mutator: :arithmetic, ignore_reason: nil}

    assert Report.ignored(with_reason) == "lib/x.ex:9  [arithmetic]  IGNORED  — deliberate"
    assert Report.ignored(without) == "lib/x.ex:9  [arithmetic]  IGNORED"
  end

  test "render/2 lists ignored mutants (with reasons) between survivors and the summary" do
    survivor = %Result{site: site(:>), status: :survived}

    ignored =
      %Result{
        status: :ignored,
        site: %Site{file: "lib/x.ex", line: 9, mutator: :arithmetic, ignore_reason: "deliberate"}
      }

    results = [survivor, ignored]
    out = Report.render(results, %{"lib/billing.ex" => @source})

    assert out =~ "lib/x.ex:9  [arithmetic]  IGNORED  — deliberate"

    # ordering: survivors, then the ignored roll-call, then the summary tally.
    assert index(out, "SURVIVED") < index(out, "IGNORED")
    assert index(out, "IGNORED") < index(out, "mutation score")
  end

  defp index(haystack, needle), do: haystack |> :binary.match(needle) |> elem(0)

  test "render/2 separates survivor blocks from each other and the summary with blank lines" do
    sites = [site(:>), site(:<=)]
    sources = %{"lib/billing.ex" => @source}

    results = [
      %Result{site: Enum.at(sites, 0), status: :survived},
      %Result{site: Enum.at(sites, 1), status: :survived}
    ]

    expected =
      Report.survivor(Enum.at(sites, 0), @source) <>
        "\n\n" <>
        Report.survivor(Enum.at(sites, 1), @source) <>
        "\n\n" <>
        Report.summary(results)

    assert Report.render(results, sources) == expected
  end
end
