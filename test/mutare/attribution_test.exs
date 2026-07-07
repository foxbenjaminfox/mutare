defmodule Mutare.AttributionTest do
  @moduledoc """
  The per-mutation report-location override (`Mutare.Mutator.Mutation`'s `:attribution`, built with
  `Mutation.at/2` / `at_drop/1`).

  A mutator that returns a **whole-node rewrite** — one that rebuilds and returns an entire
  registered-macro call from `mutate/1,2` — used to report every mutant at the call's own line, so a
  multi-line query collapsed its clause mutants onto the `query(` line and `# mutare:ignore`
  (line-keyed) could only suppress the whole query at once. Attribution decouples *where the mutant
  is reported* (a named inner clause) from *what is spliced into the metamutant* (the whole rewrite),
  so each mutant locates, diffs, and ignores per clause. Exercised through
  `Mutare.Test.AttributedQueryMutator` (a reduced analog of `mutare_ecto`'s whole-`from` rewrites).
  """
  use ExUnit.Case, async: true

  alias Mutare.Mutator.Mutation

  @source """
  defmodule UsesQuery do
    import Mutare.Test.QueryDSL

    def run(y) do
      query(
        where: 1 == y,
        select: 2
      )
    end
  end
  """

  # `query(` is on line 5; the `where:` clause on line 6, the `select:` clause on line 7.
  @where_line 6
  @select_line 7
  @query_line 5

  defp sites_for(source, mutators \\ [Mutare.Test.AttributedQueryMutator]) do
    {_metamutant, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: mutators)

    sites
  end

  describe "Mutation.at/2 and at_drop/1 construction and validation" do
    test "at/2 carries the original and mutated clause" do
      assert %Mutation.Attribution{original: :asc, mutated: :desc} = Mutation.at(:asc, :desc)
    end

    test "at_drop/1 marks the mutated side as :drop" do
      assert %Mutation.Attribution{original: :clause, mutated: :drop} = Mutation.at_drop(:clause)
    end

    test "new/2 accepts an :attribution built by the constructors" do
      attribution = Mutation.at(:a, :b)
      assert Mutation.new(:node, attribution: attribution).attribution == attribution
    end

    test "new/2 rejects an :attribution that is not an Attribution struct" do
      assert_raise ArgumentError, ~r/:attribution must be built with Mutation.at/, fn ->
        Mutation.new(:node, attribution: {:not, :an, :attribution})
      end
    end
  end

  describe "attributed whole-node rewrites" do
    test "each mutant is located at its attributed clause, not the macro line" do
      sites = sites_for(@source)

      assert Enum.map(sites, & &1.mutator) == [:attributed_query, :attributed_query]
      refute Enum.any?(sites, &(&1.line == @query_line))

      replace = Enum.find(sites, &(&1.operation == :replace))
      drop = Enum.find(sites, &(&1.operation == :delete))

      assert replace.line == @where_line
      assert drop.line == @select_line
    end

    test "the recorded diff is clause-level, not the whole query" do
      replace = Enum.find(sites_for(@source), &(&1.operation == :replace))

      assert replace.original_code == "1 == y"
      assert replace.mutated_code == ":mutated"

      assert Mutare.Report.diff(replace, @source) ==
               "-      where: 1 == y,\n+      where: :mutated,"
    end

    test "a clause drop renders a delete-style diff over the raw source line" do
      drop = Enum.find(sites_for(@source), &(&1.operation == :delete))

      assert drop.mutated_code == ""
      assert Mutare.Report.diff(drop, @source) == "-      select: 2"
    end

    test "a dropped keyword-pair clause renders its summary in key: value form" do
      drop = Enum.find(sites_for(@source), &(&1.operation == :delete))

      # Not the bare `{:select, 2}` tuple Sourceror/Macro render for a pair outside a list.
      assert drop.original_code == "select: 2"
      assert Mutare.Site.describe(drop) == "attributed_query  (drop) select: 2"
    end

    test "the metamutant still splices the whole rewrite (it compiles)" do
      {metamutant, _sites, _next} =
        Mutare.Transform.transform_string_with_sites(@source,
          mutators: [Mutare.Test.AttributedQueryMutator]
        )

      assert {:ok, _ast} = Code.string_to_quoted(metamutant)
    end
  end

  describe "# mutare:ignore keyed on the attributed clause line" do
    test "an ignore on one clause's line suppresses only that clause's mutant" do
      ignored =
        String.replace(
          @source,
          "where: 1 == y,",
          "where: 1 == y, # mutare:ignore[attributed_query]"
        )

      sites = sites_for(ignored)

      where_site = Enum.find(sites, &(&1.line == @where_line))
      select_site = Enum.find(sites, &(&1.line == @select_line))

      assert where_site.ignored,
             "the attributed where-clause mutant should be suppressible per line"

      refute select_site.ignored, "the select-clause mutant on another line stays live"
    end
  end

  describe "a mis-placed attribution degrades safely" do
    test "core warns and falls back to the offered node when the clause can't be placed" do
      ref = make_ref()

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          sites = sites_for(@source, [Mutare.Test.MisattributedQueryMutator])
          Process.put(ref, sites)
        end)

      assert warning =~ "ignoring a mutation :attribution"

      assert [site] = Process.get(ref)
      # Fell back to the offered `query(...)` node rather than mislocating or crashing.
      assert site.line == @query_line
    end
  end
end
