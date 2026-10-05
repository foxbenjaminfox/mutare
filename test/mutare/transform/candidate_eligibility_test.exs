defmodule Mutare.Transform.Candidate.EligibilityTest do
  use ExUnit.Case, async: true

  alias Mutare.AST
  alias Mutare.Transform.Candidate
  alias Mutare.Transform.Candidate.Eligibility

  @range %{start: [line: 1, column: 1], end: [line: 1, column: 5]}

  defp spec, do: Mutare.Mutator.Spec.for_module(Mutare.Mutators.Relational)
  defp op(o), do: {o, [], [{:a, [], nil}, {:b, [], nil}]}

  describe "gate/2 duplicate return constants" do
    test "node-level constants win regardless of order, literal wrapping, or metadata" do
      for value <- [:mutare, nil, false, 0, 0.0, "mutare"] do
        node = in_place(mutated: {:__block__, [line: 10], [value]})
        return = return(value)

        assert gate([node, return]) === [node]
        assert gate([return, node]) === [node]
        assert gate([return]) === [return]
      end
    end

    test "integer and float replacements remain distinct" do
      node = in_place(mutated: AST.literal(0))
      return = return(AST.literal(0.0))

      assert gate([node, return]) === [node, return]
    end

    test "a candidate removed by its policy cannot suppress a return replacement" do
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.AtomLiteral)

      node =
        in_place(
          mutator: %{spec | opts: [call_option_keys: false]},
          call_option_key?: true,
          mutated: AST.literal(:mutare)
        )

      return = return(AST.literal(:mutare))
      assert gate([node, return]) == [return]
    end

    test "non-scalar replacements and other candidate kinds are left alone" do
      for replacement <- [op(:+), AST.literal([])] do
        candidates = [in_place(mutated: replacement), return(replacement)]

        assert gate(candidates) == candidates
      end

      candidates = [
        %Candidate.RescueNarrow{
          replacement: AST.literal(:mutare),
          report: Candidate.Report.replace(op(:>=), op(:>), @range)
        },
        return(AST.literal(:mutare))
      ]

      assert gate(candidates) == candidates
    end
  end

  defp in_place(opts) do
    mutated = Keyword.get(opts, :mutated, op(:>))

    struct!(
      Candidate.InPlace,
      Keyword.merge(
        [
          mutator: spec(),
          original: op(:>=),
          mutated: mutated,
          report: Candidate.Report.new(op(:>=), mutated, @range)
        ],
        opts
      )
    )
  end

  defp return(constant),
    do: %Candidate.Return{
      mutator: spec(),
      mutated: constant,
      report: Candidate.Report.replace(op(:>=), constant, @range)
    }

  # A node binding nothing: the binding-drop withholding (`binding_export_test.exs`) is inert.
  defp gate(candidates), do: Eligibility.gate(candidates, {:site, [], []})
end
