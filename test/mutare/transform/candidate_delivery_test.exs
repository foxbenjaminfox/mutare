defmodule Mutare.Transform.Candidate.DeliveryTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.Candidate
  alias Mutare.Transform.Candidate.Delivery

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
end
