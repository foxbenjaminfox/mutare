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
    %{sites: sites} =
      Mutare.Transform.transform_string_with_sites(@source, file: "lib/billing.ex")

    Enum.find(sites, &(&1.original_form == :>= and &1.mutated_form == op_to))
  end

  test "diff/2 patches the original at the site range, leaving the line otherwise intact" do
    assert Report.diff(site(:>), @source) ==
             "-    total >= threshold\n+    total > threshold"
  end

  # A source line past the formatter's 98 columns. Sourceror at its default width would re-flow
  # the mutated fragment across two lines while the `-` side (source bytes) stays one, so the
  # reader has to hunt for the `and → or` across a re-wrap.
  @long_source """
  defmodule Probe do
    def f(user_record, account_settings, notification_preferences) do
      user_record.enabled and account_settings.active and notification_preferences.email_allowed and user_record.age > 18
    end
  end
  """

  test "diff/2 keeps a long single-line original's mutation on one line (no 98-column re-flow)" do
    %{sites: sites} =
      Mutare.Transform.transform_string_with_sites(@long_source, file: "p.ex")

    # The outermost `and → or`, spanning the whole 116-column expression.
    site =
      sites
      |> Enum.filter(&(&1.mutator == :logical))
      |> Enum.max_by(& &1.range.end[:column])

    assert Report.diff(site, @long_source) ==
             "-    user_record.enabled and account_settings.active and notification_preferences.email_allowed and user_record.age > 18\n" <>
               "+    (user_record.enabled and account_settings.active and notification_preferences.email_allowed) or user_record.age > 18"
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
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@kw_source, mutators: [mutator])

      Enum.find(sites, &(&1.original_code == original_code))
    end

    test "a boolean value swap keeps the closing paren (true/false range is not over-wide)" do
      assert Report.diff(kw_site(Mutare.Mutators.BooleanLiteral, "true"), @kw_source) ==
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
            {Mutare.Mutators.BooleanLiteral, "true"},
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
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@rx_source,
          mutators: [Mutare.Mutators.RegexLiteral]
        )

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
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@rx_source,
          mutators: [Mutare.Mutators.RegexLiteral]
        )

      for site <- sites do
        assert {:ok, _} = Code.string_to_quoted(Report.patch(site, @rx_source))
      end
    end
  end

  # Regression: an interpolated string that escapes its quote *after* the last
  # interpolation (`"set to \"#{x}\"."`) used to render corrupt survivor diffs —
  # the same tokenizer collapse as the sigil case above (`\"` stored as `"`), so
  # the range ended one column short and the whole-string swap left the original
  # closing quote behind: `toast(""")` / `toast("mutare"")`.
  # See `Mutare.Transform.NodeRange`.
  describe "diff/2 of an interpolated string with an escaped quote" do
    @str_source ~S"""
    defmodule M do
      def f(new_status), do: toast("User status set to \"#{new_status}\".")
    end
    """

    defp str_site(mutated_code) do
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@str_source,
          mutators: [Mutare.Mutators.StringLiteral]
        )

      Enum.find(sites, &(&1.mutated_code == mutated_code))
    end

    test "the empty-string swap consumes the whole literal (no stray quote)" do
      assert Report.diff(str_site(~S{""}), @str_source) ==
               ~S|-  def f(new_status), do: toast("User status set to \"#{new_status}\".")| <>
                 "\n" <> ~S|+  def f(new_status), do: toast("")|
    end

    test "the sentinel swap consumes the whole literal (no stray quote)" do
      assert Report.diff(str_site(~S{"mutare"}), @str_source) ==
               ~S|-  def f(new_status), do: toast("User status set to \"#{new_status}\".")| <>
                 "\n" <> ~S|+  def f(new_status), do: toast("mutare")|
    end

    test "every string mutant's patch re-parses as valid Elixir" do
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@str_source,
          mutators: [Mutare.Mutators.StringLiteral]
        )

      for site <- sites do
        assert {:ok, _} = Code.string_to_quoted(Report.patch(site, @str_source))
      end
    end
  end

  # Interpolated atoms and charlists mutate as a whole (`AtomLiteral`/`CharlistLiteral`);
  # their diffs must patch the full literal. The keyword-shorthand key form (`"k#{x}": v`)
  # is the sharp edge: its range must cover the trailing colon and both diff sides render
  # in keyword form (see `Mutare.Transform.NodeRange` / `Mutare.Site`).
  describe "diff/2 of interpolated atoms and charlists" do
    @ia_source ~S"""
    defmodule M do
      def f(x), do: :"pre_#{x}_post"
      def g(x), do: %{"k#{x}": 1}
      def h(x), do: ~c"a#{x}b"
    end
    """

    defp ia_sites do
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@ia_source,
          mutators: [Mutare.Mutators.AtomLiteral, Mutare.Mutators.CharlistLiteral]
        )

      sites
    end

    defp ia_site(mutator, line, mutated_code) do
      Enum.find(
        ia_sites(),
        &(&1.mutator == mutator and &1.line == line and &1.mutated_code == mutated_code)
      )
    end

    test "a whole-atom swap consumes the full interpolated literal" do
      assert Report.diff(ia_site(:atom, 2, ":mutare"), @ia_source) ==
               ~S|-  def f(x), do: :"pre_#{x}_post"| <>
                 "\n" <> ~S|+  def f(x), do: :mutare|
    end

    test "a keyword-shorthand key swap consumes the colon and renders keyword form" do
      assert Report.diff(ia_site(:atom, 3, "mutare:"), @ia_source) ==
               ~S|-  def g(x), do: %{"k#{x}": 1}| <>
                 "\n" <> ~S|+  def g(x), do: %{mutare: 1}|
    end

    test "an interpolated-charlist swap consumes the full sigil" do
      assert Report.diff(ia_site(:charlist, 4, ~S|~c"mutare"|), @ia_source) ==
               ~S|-  def h(x), do: ~c"a#{x}b"| <>
                 "\n" <> ~S|+  def h(x), do: ~c"mutare"|
    end

    test "every mutant's patch re-parses as valid Elixir" do
      for site <- ia_sites() do
        assert {:ok, _} = Code.string_to_quoted(Report.patch(site, @ia_source))
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

  test "summary/1 surfaces timeouts when present" do
    results = [%Result{status: :killed}, %Result{status: :timeout}, %Result{status: :survived}]

    assert Report.summary(results) ==
             "mutation score: 66.7%  (1 killed, 1 timeout, 1 survived, 3 total)"
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

  test "summary/1 surfaces ignored when present" do
    results = [%Result{status: :killed}, %Result{status: :survived}, %Result{status: :ignored}]
    assert Report.summary(results) =~ "1 ignored"
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

  test "summary/1 shows an absent always-in-summary status as 0, not a garbage default" do
    # `count/3` defaults a missing status to 0; killed is always rendered, so a lone
    # survivor must read "0 killed" (a wrong default would surface as "-1 killed").
    assert Report.summary([%Result{status: :survived}]) ==
             "mutation score: 0.0%  (0 killed, 1 survived, 1 total)"
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

  test "harness_error/1 renders file:line, mutator, and the diagnostic" do
    result = %Result{
      site: %Site{file: "lib/x.ex", line: 9, mutator: :arithmetic},
      status: :harness_error,
      exit_status: 99,
      output: "** (RuntimeError) checkout failed"
    }

    assert Report.harness_error(result) ==
             "lib/x.ex:9  [arithmetic]  HARNESS_ERROR  — exit 99; ** (RuntimeError) checkout failed"
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

  test "render/2 puts each ignored mutant on its own line" do
    ignored = fn line ->
      %Result{
        status: :ignored,
        site: %Site{file: "lib/x.ex", line: line, mutator: :arithmetic, ignore_reason: nil}
      }
    end

    out = Report.render([ignored.(1), ignored.(2)], %{})

    # The roll-call joins with "\n"; a dropped/altered separator would collapse the
    # two lines together.
    assert out =~ "lib/x.ex:1  [arithmetic]  IGNORED\nlib/x.ex:2  [arithmetic]  IGNORED"
  end

  test "render/2 lists harness errors before the summary" do
    error = %Result{
      status: :harness_error,
      site: %Site{file: "lib/x.ex", line: 9, mutator: :arithmetic},
      exit_status: 99,
      output: "** (RuntimeError) checkout failed"
    }

    out = Report.render([error], %{})

    assert out =~
             "lib/x.ex:9  [arithmetic]  HARNESS_ERROR  — exit 99; ** (RuntimeError) checkout failed"

    assert index(out, "HARNESS_ERROR") < index(out, "mutation score")
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
