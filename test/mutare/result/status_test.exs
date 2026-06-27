defmodule Mutare.Result.StatusTest do
  use ExUnit.Case, async: true

  alias Mutare.Result
  alias Mutare.Result.Status

  describe "totality" do
    test "the registry covers exactly the Mutare.Result.status/0 type" do
      # The registry is the single source of every per-status fact; the `@type status`
      # union is the canonical vocabulary the reporters and the runner share. This pins
      # them together: add a status to one but not the other and this fails — the
      # drift-proofing the registry exists for (CLAUDE.md "Result statuses").
      assert MapSet.new(Status.names()) == MapSet.new(status_type_atoms())
    end

    test "fetch!/1 is total over the type" do
      for status <- status_type_atoms() do
        descriptor = Status.fetch!(status)
        assert descriptor.name == status
        assert is_binary(descriptor.json) and descriptor.json != ""
        assert is_binary(descriptor.summary_label) and descriptor.summary_label != ""
      end
    end

    test "fetch!/1 raises on an unregistered status" do
      assert_raise KeyError, fn -> Status.fetch!(:not_a_status) end
    end

    test "get/1 returns nil for an unregistered status" do
      assert Status.get(:not_a_status) == nil
    end
  end

  describe "classification (the source of Mutare.Result.kill?/scored?/ran?)" do
    # Pinned so a flipped descriptor flag is a conscious, reviewed change rather than a
    # silent rescore. `Mutare.Result`'s predicates derive their lists from these fields.
    @expected_kills [:killed, :timeout, :atom_exhausted]
    @expected_unscored [:no_coverage, :ignored, :poisoned, :harness_error]
    @expected_unran [:no_coverage, :ignored, :poisoned]

    test "kill? matches the kills" do
      assert sorted(Status.where(:kill?)) == sorted(@expected_kills)

      for status <- Status.names() do
        assert Result.kill?(status) == status in @expected_kills
      end
    end

    test "scored? excludes the unscored statuses" do
      for status <- Status.names() do
        assert Result.scored?(status) == status not in @expected_unscored
      end
    end

    test "ran? excludes the unran statuses" do
      for status <- Status.names() do
        assert Result.ran?(status) == status not in @expected_unran
      end
    end
  end

  describe "render facts" do
    test "names/0 is in summary/counter render order" do
      assert Status.names() == [
               :killed,
               :timeout,
               :atom_exhausted,
               :survived,
               :no_coverage,
               :ignored,
               :poisoned,
               :harness_error
             ]
    end

    test "only :killed and :survived are pinned into the summary at zero" do
      assert Status.where(:always_in_summary?) == [:killed, :survived]
    end

    test "the JSON field maps onto the schema's MutantStatus vocabulary" do
      mapping = Map.new(Status.all(), &{&1.name, &1.json})

      assert mapping == %{
               killed: "Killed",
               survived: "Survived",
               no_coverage: "NoCoverage",
               timeout: "Timeout",
               atom_exhausted: "Timeout",
               ignored: "Ignored",
               poisoned: "CompileError",
               harness_error: "RuntimeError"
             }
    end

    test ":killed and :survived carry no live counter extra (they own the headline)" do
      assert Status.fetch!(:killed).extra_label == nil
      assert Status.fetch!(:survived).extra_label == nil
    end
  end

  # The atoms in the `Mutare.Result.status/0` type union, read straight from the
  # compiled type so the test can't itself drift from the typespec.
  defp status_type_atoms do
    {:ok, types} = Code.Typespec.fetch_types(Result)

    {:type, {:status, ast, []}} =
      Enum.find(types, fn {kind, {name, _, _}} -> kind == :type and name == :status end)

    type_atoms(ast)
  end

  defp type_atoms({:type, _, :union, members}), do: Enum.flat_map(members, &type_atoms/1)
  defp type_atoms({:atom, _, atom}), do: [atom]

  defp sorted(list), do: Enum.sort(list)
end
