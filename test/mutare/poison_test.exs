defmodule Mutare.PoisonTest do
  @moduledoc "Compile-poisoning: detect the offending mutant, drop it, recover."
  use ExUnit.Case, async: false

  alias Mutare.{Poison, Result}

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
    test "maps a compile error's file:line to the mutant id at that line" do
      {meta, [site], _next_id} = Mutare.transform_string(@src, @poison)

      line =
        meta
        |> String.split("\n")
        |> Enum.find_index(&(&1 =~ "mutare_unbound_xyz"))
        |> Kernel.+(1)

      error = "lib/p.ex:#{line}:5: undefined variable \"mutare_unbound_xyz\""
      assert Poison.ids(error, %{"lib/p.ex" => meta}) == MapSet.new([site.id])
    end

    test "returns empty when nothing maps (caller then aborts)" do
      assert Poison.ids("some unrelated error", %{}) == MapSet.new()
    end
  end

  describe "end to end recovery" do
    @tag :runner
    @tag timeout: 180_000
    test "a poisoning mutant is dropped (:poisoned) and the rest of the run proceeds" do
      base = Path.join(System.tmp_dir!(), "mutare_pz_#{System.unique_integer([:positive])}")
      project = Path.join(base, "p")
      sandbox = Path.join(base, "sandbox")
      write_project(project)
      on_exit(fn -> File.rm_rf!(base) end)

      mutators = [Mutare.Test.PoisonMutator, Mutare.Mutators.Relational]
      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: mutators)

      # add/2's `+` mutates to an unbound var → poison → dropped, not aborted.
      assert [%Result{site: %{original_op: :+}, status: :poisoned}] =
               Enum.filter(run.results, &(&1.status == :poisoned))

      # gte?/2's relational mutants still ran and were killed.
      assert Enum.count(run.results, &(&1.status == :killed)) == 2
      assert Mutare.Report.score(run.results) == 100.0
    end
  end

  defp write_project(project) do
    write(project, "mix.exs", """
    defmodule P.MixProject do
      use Mix.Project
      def project, do: [app: :p, version: "0.1.0", elixir: "~> 1.15"]
      def application, do: []
    end
    """)

    write(project, "lib/p.ex", """
    defmodule P do
      def add(a, b), do: a + b
      def gte?(a, b), do: a >= b
    end
    """)

    write(project, "test/test_helper.exs", "ExUnit.start()\n")

    write(project, "test/p_test.exs", """
    defmodule PTest do
      use ExUnit.Case
      test "gte boundary" do
        assert P.gte?(5, 5)
        refute P.gte?(4, 5)
      end
    end
    """)
  end

  defp write(project, rel, contents) do
    path = Path.join(project, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
