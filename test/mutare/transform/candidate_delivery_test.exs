defmodule Mutare.Transform.Candidate.DeliveryTest do
  use ExUnit.Case, async: true

  alias Mutare.Site
  alias Mutare.Transform.Candidate
  alias Mutare.Transform.Candidate.Delivery

  @range %{start: [line: 1, column: 1], end: [line: 1, column: 5]}

  defp spec, do: Mutare.Mutator.Spec.for_module(Mutare.Mutators.Relational)
  defp op(o), do: {o, [], [{:a, [], nil}, {:b, [], nil}]}
  defp clause, do: Sourceror.parse_string!("def f(_), do: :ok")

  describe "classify_node_candidates/1" do
    test "fn clauses share delivery with whole-node offers and later return candidates" do
      candidates = [
        in_place(),
        %Candidate.FnClause{report: report()},
        %Candidate.Return{report: report()}
      ]

      assert Delivery.classify_node_candidates(candidates) == {:fn_clause, candidates}
    end

    test "receive clauses share delivery with whole-node candidates without admitting other clause kinds" do
      candidates = [
        in_place(),
        %Candidate.ReceiveClause{report: report()},
        %Candidate.Return{report: report()}
      ]

      assert Delivery.classify_node_candidates(candidates) == {:receive_clause, candidates}

      assert_raise RuntimeError, ~r/candidate delivery route mismatch/, fn ->
        Delivery.classify_node_candidates([
          %Candidate.ReceiveClause{report: report()},
          %Candidate.FnClause{report: report()}
        ])
      end
    end

    test "classifies every node-local delivery route" do
      assert Delivery.classify_node_candidates([]) == :none

      assert {:in_place,
              [
                %Candidate.InPlace{},
                %Candidate.Return{},
                %Candidate.RescueNarrow{},
                %Candidate.RescueDrop{}
              ]} =
               Delivery.classify_node_candidates([
                 in_place(),
                 %Candidate.Return{report: report()},
                 %Candidate.RescueNarrow{report: report()},
                 %Candidate.RescueDrop{report: report()}
               ])

      assert {:case_clause, [%Candidate.CaseClause{}]} =
               Delivery.classify_node_candidates([%Candidate.CaseClause{report: report()}])

      assert {:match_pattern, [%Candidate.MatchPattern{}]} =
               Delivery.classify_node_candidates([%Candidate.MatchPattern{report: report()}])

      assert {:macro_pattern, [%Candidate.MacroPattern{}]} =
               Delivery.classify_node_candidates([%Candidate.MacroPattern{report: report()}])
    end

    test "rejects candidates owned by dedicated non-node-local emit paths" do
      for candidate <- [%Candidate.Lifted{report: report()}, %Candidate.Hosted{}] do
        assert_raise ArgumentError, ~r/not a node-local candidate/, fn ->
          Delivery.classify_node_candidates([candidate])
        end
      end
    end

    test "rejects a heterogeneous node-local candidate list" do
      assert_raise RuntimeError, ~r/candidate delivery route mismatch/, fn ->
        Delivery.classify_node_candidates([
          in_place(),
          %Candidate.CaseClause{report: report()}
        ])
      end
    end
  end

  describe "route/1" do
    # Every variant has a `profile/1` row (so `route/1` never falls through), and each reports
    # the route its emit path expects — node-local for the seven node candidates, `:lifted` /
    # `:hosted` for the candidates routed by FunctionPlan / HostedEmit.
    test "reports the delivery route of every candidate variant" do
      routes = [
        {in_place(), :in_place},
        {%Candidate.Return{report: report()}, :in_place},
        {%Candidate.RescueNarrow{report: report()}, :in_place},
        {%Candidate.RescueDrop{report: report()}, :in_place},
        {%Candidate.CaseClause{report: report()}, :case_clause},
        {%Candidate.FnClause{report: report()}, :fn_clause},
        {%Candidate.ReceiveClause{report: report()}, :receive_clause},
        {%Candidate.MatchPattern{report: report()}, :match_pattern},
        {%Candidate.MacroPattern{report: report()}, :macro_pattern},
        {%Candidate.Lifted{report: report()}, :lifted},
        {%Candidate.PatternStructure{report: report()}, :lifted},
        {%Candidate.GuardDrop{report: report()}, :lifted},
        {%Candidate.Drop{report: report()}, :lifted},
        {%Candidate.Hosted{}, :hosted}
      ]

      for {candidate, expected} <- routes do
        assert Delivery.route(candidate) == expected,
               "expected #{inspect(candidate.__struct__)} to route #{inspect(expected)}"
      end
    end
  end

  describe "selector_branch/1" do
    test "reads the mutant-branch field of each in-place-routed candidate" do
      mutated = op(:>)
      replacement = op(:<)

      assert Delivery.selector_branch(in_place(mutated: mutated)) == mutated

      assert Delivery.selector_branch(%Candidate.Return{mutated: mutated, report: report()}) ==
               mutated

      assert Delivery.selector_branch(%Candidate.RescueNarrow{
               replacement: replacement,
               report: report()
             }) == replacement

      assert Delivery.selector_branch(%Candidate.RescueDrop{
               replacement: replacement,
               report: report()
             }) == replacement
    end
  end

  describe "site/4" do
    test "in-place / case-clause / match-pattern / macro-pattern record an :in_place :replace site" do
      for candidate <- [
            in_place(),
            %Candidate.CaseClause{mutator: spec(), report: report()},
            %Candidate.FnClause{mutator: spec(), report: report()},
            %Candidate.ReceiveClause{mutator: spec(), report: report()},
            %Candidate.ClauseGuard{mutator: spec(), report: report()},
            %Candidate.MatchPattern{mutator: spec(), report: report()},
            %Candidate.MacroPattern{mutator: spec(), report: report()},
            %Candidate.RescueNarrow{mutator: spec(), report: report()}
          ] do
        site = Delivery.site(7, candidate, "lib/x.ex", {true, false})
        assert %Site{id: 7, kind: :in_place, operation: :replace, mutator: :relational} = site
        assert site.original_form == :>=
      end
    end

    test "a re-homed deletion retains its checked range, selection position and carried labels" do
      original = Sourceror.parse_string!("foo(
  bar()
)")
      {:foo, _, [inner]} = original
      range = Mutare.Transform.NodeRange.get(original)
      attribution = %{Mutare.Mutator.Mutation.at_drop(inner) | position: range.start}
      report = Candidate.Report.new(original, original, range, attribution, variant: :drop)
      in_place = in_place(original: original, mutated: original, report: report)
      rehomed = %Candidate.MacroPattern{report: report, mutator: spec()}

      for candidate <- [in_place, rehomed] do
        site = Delivery.site(7, candidate, "lib/x.ex", {true, false})
        assert site.operation == :delete
        assert site.original_code == "bar()"
        assert site.mutated_code == ""
        assert site.variant == ["drop"]
        assert site.range.start[:line] == 2
        assert {site.line, site.column} == Delivery.position(candidate)
        assert site.line == 1
      end
    end

    test "a return candidate records an :in_place :replace site with no original form" do
      candidate = %Candidate.Return{
        mutator: spec(),
        mutated: nil,
        report: Candidate.Report.replace(op(:>=), nil, @range)
      }

      site = Delivery.site(7, candidate, "lib/x.ex", {true, false})

      assert %Site{kind: :in_place, operation: :replace, mutator: :relational} = site
      # return_value/6 keeps no AST form (the replacement is a bare constant).
      assert site.original_form == nil
    end

    test "lifted candidates record a :lifted :replace site" do
      for candidate <- [
            %Candidate.Lifted{mutator: spec(), mutated: op(:>), report: report()},
            %Candidate.LiftedGuard{mutator: spec(), mutated: op(:>), report: report()},
            %Candidate.PatternStructure{mutator: spec(), report: report()},
            %Candidate.GuardDrop{mutator: spec(), report: report()}
          ] do
        site = Delivery.site(7, candidate, "lib/x.ex", {true, false})
        assert %Site{kind: :lifted, operation: :replace, mutator: :relational} = site
      end
    end

    test "a rescue-drop records an in-place :delete site" do
      candidate = %Candidate.RescueDrop{
        mutator: spec(),
        report: Candidate.Report.delete(clause(), @range)
      }

      site = Delivery.site(7, candidate, "lib/x.ex", {true, false})

      assert %Site{kind: :in_place, operation: :delete, mutator: :relational} = site
    end

    test "a clause-drop records a lifted :delete site under the clause_drop mutator" do
      candidate = %Candidate.Drop{report: Candidate.Report.delete(clause(), @range)}
      site = Delivery.site(7, candidate, "lib/x.ex", {true, false})

      assert %Site{kind: :lifted, operation: :delete, mutator: :clause_drop} = site
    end

    test "a hosted candidate has no site/4 path (HostedEmit records its Sites per mutant)" do
      assert_raise ArgumentError, ~r/records its Sites per mutant in HostedEmit/, fn ->
        Delivery.site(7, %Candidate.Hosted{}, "lib/x.ex", {true, false})
      end
    end

    test "render? false defers the diff code (the scan's deferral), keeping every other field" do
      candidate = in_place()

      eager = Delivery.site(7, candidate, "lib/x.ex", {true, false})
      deferred = Delivery.site(7, candidate, "lib/x.ex", {false, false})

      # Deferred records no diff text...
      assert deferred.original_code == nil
      assert deferred.mutated_code == nil

      # ...but is otherwise identical to the eager site (id, classification, form, range).
      assert eager.original_code == "a >= b"

      assert %{deferred | original_code: eager.original_code, mutated_code: eager.mutated_code} ==
               eager
    end

    test "the summary flag is independent of render? (the live line on a deferred scan)" do
      candidate = in_place()

      # Deferred *_code, but summary on — the `mix mutare` non-quiet path.
      site = Delivery.site(7, candidate, "lib/x.ex", {false, true})
      assert site.original_code == nil
      assert site.summary == "relational  a >= b → a > b"

      # ...and off by default leaves it nil (eager render, no live reporter).
      assert Delivery.site(7, candidate, "lib/x.ex", {true, false}).summary == nil
    end
  end

  defp report, do: Candidate.Report.replace(op(:>=), op(:>), @range)

  defp in_place(opts \\ []) do
    original = Keyword.get(opts, :original, op(:>=))
    mutated = Keyword.get(opts, :mutated, op(:>))

    struct!(
      Candidate.InPlace,
      Keyword.merge(
        [
          mutator: spec(),
          original: original,
          mutated: mutated,
          report: Candidate.Report.new(original, mutated, @range)
        ],
        opts
      )
    )
  end
end
