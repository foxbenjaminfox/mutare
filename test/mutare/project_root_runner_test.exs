defmodule Mutare.ProjectRootRunnerTest do
  @moduledoc """
  End-to-end check that every sandbox `mix` names the directory the sandbox copies
  under `MUTARE_PROJECT_ROOT` (`Mutare.Sandbox.Command.Invocation.project_root_env/0`).

  The fixture's `config/config.exs` raises unless the variable is the fixture
  project's own path. Mix evaluates that config in every sandbox `mix` — the one
  compile, the baseline, the coverage probe, each mutant run — so a run that missed
  it fails to boot:

    * a finished run proves the compile, baseline and probe saw it;
    * the relational `>= -> >` mutant *surviving* proves the per-mutant runs saw it:
      a mutant run that fails to boot records as a kill, so a missing variable
      would turn it into a false one.

  The expected path is the fixture's, written after it is built, so neither the
  sandbox's own path nor a value inherited from an outer Mutare run can satisfy it.
  """
  # Subprocess-bound: runs beside the in-process tests, one module at a time within its
  # group (`test_helper.exs` says why there are three).
  use ExUnit.Case, async: true, group: :subprocess_3

  alias Mutare.Result
  alias Mutare.Sandbox.Command.Invocation
  alias Mutare.Test.Project

  @moduletag :runner
  # compile + baseline + probe + one subprocess per mutant
  @moduletag timeout: 180_000

  test "every sandbox mix is told the original project root" do
    %{project: project, sandbox: sandbox} =
      Project.build(:project_root, %{
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

          # No boundary test, so the relational `>= -> >` mutant survives.
          test "gte? is true well above the threshold" do
            assert Calc.gte?(10, 5) == true
          end
        end
        """
      })

    var = Invocation.project_root_env()
    expected = Path.expand(project)

    File.mkdir_p!(Path.join(project, "config"))

    File.write!(Path.join(project, "config/config.exs"), """
    import Config

    case System.get_env(#{inspect(var)}) do
      #{inspect(expected)} -> :ok
      other -> raise "#{var} is \#{inspect(other)}, not #{expected}"
    end
    """)

    assert {:ok, run} =
             Mutare.run(project,
               sandbox: sandbox,
               mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational],
               workers: 2
             )

    assert length(run.results) == 3
    assert Enum.count(run.results, &(&1.status == :killed)) == 2

    assert [%Result{site: %{mutator: :relational, original_form: :>=, mutated_form: :>}}] =
             Enum.filter(run.results, &(&1.status == :survived))
  end
end
