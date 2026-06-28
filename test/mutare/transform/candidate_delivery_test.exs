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
    test "classifies every node-local delivery route" do
      assert Delivery.classify_node_candidates([]) == :none

      assert {:in_place,
              [
                %Candidate.InPlace{},
                %Candidate.Return{},
                %Candidate.CasePattern{},
                %Candidate.RescueDrop{}
              ]} =
               Delivery.classify_node_candidates([
                 %Candidate.InPlace{},
                 %Candidate.Return{},
                 %Candidate.CasePattern{},
                 %Candidate.RescueDrop{}
               ])

      assert {:case_clause, [%Candidate.CaseClause{}]} =
               Delivery.classify_node_candidates([%Candidate.CaseClause{}])

      assert {:match_pattern, [%Candidate.MatchPattern{}]} =
               Delivery.classify_node_candidates([%Candidate.MatchPattern{}])

      assert {:macro_pattern, [%Candidate.MacroPattern{}]} =
               Delivery.classify_node_candidates([%Candidate.MacroPattern{}])
    end

    test "rejects candidates owned by dedicated non-node-local emit paths" do
      for candidate <- [%Candidate.Lifted{}, %Candidate.Hosted{}] do
        assert_raise ArgumentError, ~r/not a node-local candidate/, fn ->
          Delivery.classify_node_candidates([candidate])
        end
      end
    end

    test "rejects a heterogeneous node-local candidate list" do
      assert_raise RuntimeError, ~r/candidate delivery route mismatch/, fn ->
        Delivery.classify_node_candidates([
          %Candidate.InPlace{},
          %Candidate.CaseClause{}
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
        {%Candidate.InPlace{}, :in_place},
        {%Candidate.Return{}, :in_place},
        {%Candidate.CasePattern{}, :in_place},
        {%Candidate.RescueDrop{}, :in_place},
        {%Candidate.CaseClause{}, :case_clause},
        {%Candidate.MatchPattern{}, :match_pattern},
        {%Candidate.MacroPattern{}, :macro_pattern},
        {%Candidate.Lifted{}, :lifted},
        {%Candidate.PatternStructure{}, :lifted},
        {%Candidate.GuardDrop{}, :lifted},
        {%Candidate.Drop{}, :lifted},
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

      assert Delivery.selector_branch(%Candidate.InPlace{mutated: mutated}) == mutated
      assert Delivery.selector_branch(%Candidate.Return{mutated: mutated}) == mutated

      assert Delivery.selector_branch(%Candidate.CasePattern{replacement: replacement}) ==
               replacement

      assert Delivery.selector_branch(%Candidate.RescueDrop{replacement: replacement}) ==
               replacement
    end
  end

  describe "site/4" do
    test "in-place / case-clause / match-pattern / macro-pattern record an :in_place :replace site" do
      for candidate <- [
            %Candidate.InPlace{
              mutator: spec(),
              original: op(:>=),
              mutated: op(:>),
              range: @range
            },
            %Candidate.CaseClause{
              mutator: spec(),
              original: op(:>=),
              mutated: op(:>),
              range: @range
            },
            %Candidate.MatchPattern{
              mutator: spec(),
              original: op(:>=),
              mutated: op(:>),
              range: @range
            },
            %Candidate.MacroPattern{
              mutator: spec(),
              original: op(:>=),
              mutated: op(:>),
              range: @range
            },
            %Candidate.CasePattern{
              mutator: spec(),
              original: op(:>=),
              mutated: op(:>),
              range: @range
            }
          ] do
        site = Delivery.site(7, candidate, "lib/x.ex", true)
        assert %Site{id: 7, kind: :in_place, operation: :replace, mutator: :relational} = site
        assert site.original_form == :>=
      end
    end

    test "a return candidate records an :in_place :replace site with no original form" do
      candidate = %Candidate.Return{
        mutator: spec(),
        original: op(:>=),
        mutated: nil,
        range: @range
      }

      site = Delivery.site(7, candidate, "lib/x.ex", true)

      assert %Site{kind: :in_place, operation: :replace, mutator: :relational} = site
      # return_value/6 keeps no AST form (the replacement is a bare constant).
      assert site.original_form == nil
    end

    test "lifted candidates record a :lifted :replace site" do
      for candidate <- [
            %Candidate.Lifted{mutator: spec(), original: op(:>=), mutated: op(:>), range: @range},
            %Candidate.PatternStructure{
              mutator: spec(),
              original: op(:>=),
              mutated: op(:>),
              range: @range
            },
            %Candidate.GuardDrop{
              mutator: spec(),
              original: op(:>=),
              mutated: op(:>),
              range: @range
            }
          ] do
        site = Delivery.site(7, candidate, "lib/x.ex", true)
        assert %Site{kind: :lifted, operation: :replace, mutator: :relational} = site
      end
    end

    test "a rescue-drop records an in-place :delete site" do
      candidate = %Candidate.RescueDrop{mutator: spec(), dropped: clause(), range: @range}
      site = Delivery.site(7, candidate, "lib/x.ex", true)

      assert %Site{kind: :in_place, operation: :delete, mutator: :relational} = site
    end

    test "a clause-drop records a lifted :delete site under the clause_drop mutator" do
      candidate = %Candidate.Drop{original: clause(), range: @range}
      site = Delivery.site(7, candidate, "lib/x.ex", true)

      assert %Site{kind: :lifted, operation: :delete, mutator: :clause_drop} = site
    end

    test "a hosted candidate has no site/4 path (HostedEmit records its Sites per mutant)" do
      assert_raise ArgumentError, ~r/records its Sites per mutant in HostedEmit/, fn ->
        Delivery.site(7, %Candidate.Hosted{}, "lib/x.ex", true)
      end
    end

    test "render? false defers the diff code (the scan's deferral), keeping every other field" do
      candidate = %Candidate.InPlace{
        mutator: spec(),
        original: op(:>=),
        mutated: op(:>),
        range: @range
      }

      eager = Delivery.site(7, candidate, "lib/x.ex", true)
      deferred = Delivery.site(7, candidate, "lib/x.ex", false)

      # Deferred records no diff text...
      assert deferred.original_code == nil
      assert deferred.mutated_code == nil

      # ...but is otherwise identical to the eager site (id, classification, form, range).
      assert eager.original_code == "a >= b"

      assert %{deferred | original_code: eager.original_code, mutated_code: eager.mutated_code} ==
               eager
    end
  end
end
