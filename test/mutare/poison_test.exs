defmodule Mutare.PoisonTest do
  @moduledoc "Compile-poisoning: detect the offending mutant, drop it, recover."
  use ExUnit.Case, async: false

  alias Mutare.{Poison, Result}
  alias Mutare.Test.Project

  @poison [mutators: [Mutare.Test.PoisonMutator], file: "lib/p.ex"]
  @src "defmodule P do\n  def f(a, b), do: a + b\nend\n"

  describe "transform :skip_ids" do
    test "a skipped id is recorded :poisoned with no selector, so it compiles" do
      {meta, [site], _next_id} = Mutare.transform_string(@src, @poison)

      # Without skipping, the poison mutant is in the metamutant (won't compile).
      assert meta =~ "mutare_unbound_xyz"

      {meta2, [site2], _next_id} =
        Mutare.transform_string(@src, Keyword.put(@poison, :skip_ids, MapSet.new([site.id])))

      assert site2.id == site.id
      assert site2.poisoned
      refute meta2 =~ "mutare_unbound_xyz"
      # And it actually compiles now.
      assert [{P, _}] = Code.compile_string(meta2)
    after
      :code.purge(P)
      :code.delete(P)
    end
  end

  describe "Poison.ids/2" do
    test "maps a compile error's file:line to the mutant whose generated code spans it" do
      {meta, [site], _next_id} = Mutare.transform_string(@src, @poison)

      line =
        meta
        |> String.split("\n")
        |> Enum.find_index(&(&1 =~ "mutare_unbound_xyz"))
        |> Kernel.+(1)

      error = "lib/p.ex:#{line}:5: undefined variable \"mutare_unbound_xyz\""
      # `Poison.ids/2` now takes the metamutant *sources* and builds the manifest
      # lazily, so the scan never pays for it on a healthy run.
      metamutants = %{"lib/p.ex" => meta}
      assert Poison.ids(error, metamutants) == MapSet.new([site.id])
    end

    test "returns empty when nothing maps (caller then aborts)" do
      assert Poison.ids("some unrelated error", %{}) == MapSet.new()
    end

    test "ignores a warning's file:line — only error diagnostics locate poison" do
      {meta, [site], _next_id} = Mutare.transform_string(@src, @poison)
      metamutants = %{"lib/p.ex" => meta}

      line =
        meta
        |> String.split("\n")
        |> Enum.find_index(&(&1 =~ "mutare_unbound_xyz"))
        |> Kernel.+(1)

      # mix footers a *warning* with the same `└─ file:line` shape as an error. A failed
      # compile prints every warning the mutations provoke; pointing one at the mutant's
      # own line must NOT flag it as poison (the bug that dropped ~110 valid plug mutants).
      warning =
        "    warning: variable \"x\" is unused\n" <>
          "    └─ lib/p.ex:#{line}:5: P.f/2\n"

      assert Poison.ids(warning, metamutants) == MapSet.new()

      # The same location inside an `error:` diagnostic *is* the poison.
      error =
        "    error: undefined variable \"mutare_unbound_xyz\"\n" <>
          "    └─ lib/p.ex:#{line}:5: P.f/2\n"

      assert Poison.ids(error, metamutants) == MapSet.new([site.id])

      # A warning sharing the output with the real error neither adds nor hides ids.
      assert Poison.ids(warning <> error, metamutants) == MapSet.new([site.id])
    end
  end

  describe "end to end recovery" do
    @tag :runner
    @tag timeout: 180_000
    test "a poisoning mutant is dropped (:poisoned) and the rest of the run proceeds" do
      %{project: project, sandbox: sandbox} =
        Project.build(:p, %{
          "lib/p.ex" => """
          defmodule P do
            def add(a, b), do: a + b
            def gte?(a, b), do: a >= b
          end
          """,
          "test/p_test.exs" => """
          defmodule PTest do
            use ExUnit.Case
            test "gte boundary" do
              assert P.gte?(5, 5)
              refute P.gte?(4, 5)
            end
          end
          """
        })

      mutators = [Mutare.Test.PoisonMutator, Mutare.Mutators.Relational]
      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: mutators)

      # add/2's `+` mutates to an unbound var → poison → dropped, not aborted.
      assert [%Result{site: %{original_op: :+}, status: :poisoned}] =
               Enum.filter(run.results, &(&1.status == :poisoned))

      # gte?/2's relational mutants still ran and were killed.
      assert Enum.count(run.results, &(&1.status == :killed)) == 2
      assert Mutare.Report.score(run.results) == 100.0
    end

    @tag :runner
    @tag timeout: 180_000
    test "a poison in a guard (lifted, bad code in a private defp) is dropped, not aborted" do
      # The regression: a guard mutation's poison lives in a generated private
      # `defp __mutare_…_m<id>`, lines away from its dispatcher clause. The old
      # line→id mapping matched only the dispatcher clause's start line, so it
      # found nothing (MapSet.new([])) and the whole run aborted. The manifest's
      # generated ranges cover the private definition, so it's now identifiable.
      %{project: project, sandbox: sandbox} =
        Project.build(:pg, %{
          "lib/pg.ex" => """
          defmodule Pg do
            def gte?(a, b) when a + 0 >= b, do: true
            def gte?(_, _), do: false
          end
          """,
          "test/pg_test.exs" => """
          defmodule PgTest do
            use ExUnit.Case
            test "gte boundary" do
              assert Pg.gte?(5, 5)
              refute Pg.gte?(4, 5)
            end
          end
          """
        })

      mutators = [Mutare.Test.PoisonMutator, Mutare.Mutators.Relational]
      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: mutators)

      # the guard's `+` poisons (→ unbound var in the lifted copy) → dropped.
      assert [%Result{site: %{original_op: :+}, status: :poisoned}] =
               Enum.filter(run.results, &(&1.status == :poisoned))

      # the surviving lifted mutants (guard relational swaps + clause drops) ran;
      # the boundary test kills them, so the run completes rather than aborting.
      refute Enum.empty?(Enum.filter(run.results, &(&1.status == :killed)))
      assert Mutare.Report.score(run.results) == 100.0
    end
  end
end
