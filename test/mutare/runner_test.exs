defmodule Mutare.RunnerTest do
  @moduledoc """
  End-to-end runner coverage: generate a tiny project, run mutation testing
  against it with real `mix test` subprocesses, and prove the whole loop:
  compile once, kill/survive classification, and a survivor diff.
  """
  use ExUnit.Case, async: false

  alias Mutare.{Report, Result}
  alias Mutare.Test.Project

  # Pin to the operator-swap families: this fixture is built around a precise
  # 3-mutant scenario (the missing boundary test), so the higher-volume default
  # mutators are excluded to keep the counts and score deterministic.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  @moduletag :runner
  # Several `mix` subprocesses (compile + baseline + one per mutant).
  @moduletag timeout: 180_000

  setup do
    Project.build(:calc, %{
      "lib/calc.ex" => """
      defmodule Calc do
        def add(a, b), do: a + b
        def gte?(a, b), do: a >= b
      end
      """,
      "test/calc_test.exs" => """
      defmodule CalcTest do
        use ExUnit.Case

        test "add sums its arguments" do
          assert Calc.add(2, 3) == 5
        end

        # Note: only tests well above the threshold — no boundary case.
        test "gte? is true well above the threshold" do
          assert Calc.gte?(10, 5) == true
        end
      end
      """
    })
  end

  test "classifies mutants and finds the missing boundary test", %{
    project: project,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    assert length(run.results) == 3
    assert Enum.count(run.results, &(&1.status == :killed)) == 2
    assert [survivor] = Enum.filter(run.results, &(&1.status == :survived))

    # The boundary test is missing for gte?/2, so `>= -> >` slips through.
    assert %Result{site: %{mutator: :relational, original_form: :>=, mutated_form: :>, line: 3}} =
             survivor
  end

  test "renders the survivor as a one-line diff with a score", %{
    project: project,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    report = Report.render(run.results, run.schema.sources)

    assert report =~ "lib/calc.ex:3  [relational, in-place]  SURVIVED"
    assert report =~ "-  def gte?(a, b), do: a >= b"
    assert report =~ "+  def gte?(a, b), do: a > b"
    assert report =~ "mutation score: 66.7%  (2 killed, 1 survived, 3 total)"
  end

  test "compiles once: no per-mutant recompilation", %{project: project, sandbox: sandbox} do
    assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: @probe)

    # If the one-compile invariant holds, no mutant run rebuilds anything.
    for %Result{output: output} <- run.results do
      refute output =~ "Compiling", "a mutant run recompiled:\n#{output}"
    end
  end

  test "removes the default throwaway sandbox when the run completes", %{project: project} do
    # No `--sandbox` and no `--keep-sandbox`: the runner materialises a throwaway
    # sandbox under the temp dir and removes it on completion, so default runs
    # don't accumulate stale dirs there.
    assert {:ok, run} = Mutare.run(project, mutators: @probe)
    on_exit(fn -> File.rm_rf(run.sandbox) end)

    refute File.exists?(run.sandbox)
  end

  test "keep_sandbox reuses the sandbox and its build across runs", %{
    project: project,
    sandbox: sandbox
  } do
    assert {:ok, first} =
             Mutare.run(project, sandbox: sandbox, mutators: @probe, keep_sandbox: true)

    assert Enum.count(first.results, &(&1.status == :killed)) == 2

    # The first run compiled the metamutant in place; that build must survive.
    build = Path.join(sandbox, "_build")
    assert File.dir?(build)
    [marker | _] = Path.wildcard(Path.join(build, "**/*.beam"))
    assert File.exists?(marker), "expected compiled .beam artifacts after the first run"

    # A second kept run against the unchanged source is still correct, and the
    # earlier build artifact is still present (it was reused, not wiped).
    assert {:ok, second} =
             Mutare.run(project, sandbox: sandbox, mutators: @probe, keep_sandbox: true)

    assert Enum.count(second.results, &(&1.status == :killed)) == 2
    assert [_] = Enum.filter(second.results, &(&1.status == :survived))
    assert File.exists?(marker)
  end
end
