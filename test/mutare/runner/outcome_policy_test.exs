defmodule Mutare.Runner.OutcomePolicyTest do
  use ExUnit.Case, async: true

  alias Mutare.Runner.OutcomePolicy
  alias Mutare.Sandbox.Command

  test "the policy covers exactly the Command.outcome/0 type" do
    assert Enum.sort(OutcomePolicy.outcomes()) == Enum.sort(outcome_type_atoms())
  end

  # Pinned so a changed status or retry budget is a reviewed change, not a silent rescore.
  test "each outcome's status and retry budget" do
    assert Map.new(OutcomePolicy.outcomes(), &{&1, OutcomePolicy.status(&1)}) == %{
             passed: :survived,
             failed: :killed,
             timeout: :timeout,
             suite_compile_error: :killed,
             atom_exhausted: :atom_exhausted,
             app_start_failure: :killed,
             harness_error: :harness_error,
             boot_failure: :harness_error,
             sigkilled: :harness_error
           }

    assert Map.new(OutcomePolicy.outcomes(), &{&1, OutcomePolicy.retry(&1)}) == %{
             passed: :none,
             failed: :none,
             timeout: :none,
             suite_compile_error: :none,
             atom_exhausted: :none,
             app_start_failure: :boot_contention,
             harness_error: :harness,
             boot_failure: :boot_contention,
             sigkilled: :none
           }
  end

  test "the kills" do
    assert Enum.sort(Enum.filter(OutcomePolicy.outcomes(), &OutcomePolicy.kill?/1)) ==
             Enum.sort([
               :failed,
               :timeout,
               :suite_compile_error,
               :atom_exhausted,
               :app_start_failure
             ])
  end

  test "the warnings" do
    assert Map.new(OutcomePolicy.outcomes(), &{&1, OutcomePolicy.warning(&1)}) == %{
             passed: :none,
             failed: :none,
             timeout: :none,
             suite_compile_error: :none,
             atom_exhausted: :none,
             app_start_failure: :contended_kill,
             harness_error: :no_verdict,
             boot_failure: :no_verdict,
             sigkilled: :no_verdict
           }
  end

  defp outcome_type_atoms do
    {:ok, types} = Code.Typespec.fetch_types(Command)

    {:type, {:outcome, ast, []}} =
      Enum.find(types, fn {kind, {name, _, _}} -> kind == :type and name == :outcome end)

    type_atoms(ast)
  end

  defp type_atoms({:type, _, :union, members}), do: Enum.flat_map(members, &type_atoms/1)
  defp type_atoms({:atom, _, atom}), do: [atom]
end
