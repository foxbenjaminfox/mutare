defmodule Mutare.KeptSandboxDepsRunnerTest do
  # Subprocess-bound: runs beside the in-process tests, one module at a time within its
  # group (`test_helper.exs` says why there are three).
  use ExUnit.Case, async: true, group: :subprocess_2

  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 300_000

  # `deps.get` tells Mix a refetched dep's build is stale by deleting its
  # `compile.elixir_scm` — in the original project's `_build`, never the kept sandbox's.
  # A local git dependency gives the dep a `mix.lock` entry the way a Hex package has one,
  # without the network. NOTES "A kept sandbox must do what `deps.get` did".
  setup do
    %{base: base, project: project, sandbox: sandbox} =
      Project.build(:kept_deps_target, %{
        "lib/kept_deps_target.ex" => """
        defmodule KeptDepsTarget do
          def f(x), do: x + KeptDep.value()
        end
        """
      })

    dep = Path.join(base, "kept_dep")
    write_dep(dep, "0.1.0", 1)
    git!(dep, ["init", "-q"])
    commit!(dep, "v1")

    %{dep: dep, project: project, sandbox: sandbox}
  end

  test "a dep upgraded past the requirement the kept sandbox was built for", context do
    target!(context, "~> 0.1.0", 2)
    assert {:ok, _} = run(context)

    upgrade!(context, "~> 0.2.0", 3)
    assert {:ok, run} = run(context)
    assert Enum.map(run.results, & &1.status) == [:killed]
  end

  test "a dep upgraded within its requirement runs the new code, not the kept build",
       context do
    target!(context, "~> 0.1", 2)
    assert {:ok, _} = run(context)

    # Mix raises nothing here: a kept build Mutare did not drop would run version 0.1.0's
    # `value/0` and fail the baseline's `f(1) == 3`.
    upgrade!(context, "~> 0.1", 3)
    assert {:ok, run} = run(context)
    assert Enum.map(run.results, & &1.status) == [:killed]
  end

  # A `git pull` that moves `mix.lock` leaves the original's build of the dep the old
  # lock's, still marked current, until `deps.get`. The run in between copies that build
  # and fails Mix's dependency check; the run after `deps.get` must not keep the copy.
  test "a run between a pulled mix.lock and deps.get leaves no build behind", context do
    target!(context, "~> 0.1", 2)
    assert {:ok, _} = run(context)

    pull_upgrade!(context, 3)
    assert {:error, :dependency_failed, _} = run(context)

    mix!(context.project, ["deps.get"])
    assert {:ok, run} = run(context)
    assert Enum.map(run.results, & &1.status) == [:killed]
  end

  defp run(context) do
    Mutare.run(context.project,
      sandbox: context.sandbox,
      keep_sandbox: true,
      mutators: [Mutare.Mutators.Arithmetic]
    )
  end

  # Point the target at the dep under `requirement`, expect `f(1) == expected`, and leave
  # the original project the way a user leaves it: fetched and tested.
  defp target!(context, requirement, expected) do
    File.write!(Path.join(context.project, "mix.exs"), """
    defmodule KeptDepsTarget.MixProject do
      use Mix.Project

      def project do
        [
          app: :kept_deps_target,
          version: "0.1.0",
          elixir: "~> 1.15",
          deps: [{:kept_dep, #{inspect(requirement)}, git: #{inspect(context.dep)}}]
        ]
      end

      def application, do: []
    end
    """)

    File.write!(Path.join(context.project, "test/kept_deps_target_test.exs"), """
    defmodule KeptDepsTargetTest do
      use ExUnit.Case
      test "f", do: assert(KeptDepsTarget.f(1) == #{expected})
    end
    """)

    mix!(context.project, ["deps.get"])
    mix!(context.project, ["test"])
  end

  defp upgrade!(context, requirement, expected) do
    write_dep(context.dep, "0.2.0", 2)
    commit!(context.dep, "v2")
    mix!(context.project, ["deps.update", "kept_dep"])
    target!(context, requirement, expected)
  end

  # What a `git pull` brings in after someone else upgraded the dep: their `mix.lock`
  # and the test that expects the new value, with this checkout's `deps/` and `_build`
  # left as they were.
  defp pull_upgrade!(context, expected) do
    write_dep(context.dep, "0.2.0", 2)
    commit!(context.dep, "v2")
    upstream = context.project <> "_upstream"
    File.cp_r!(context.project, upstream)
    mix!(upstream, ["deps.update", "kept_dep"])
    File.cp!(Path.join(upstream, "mix.lock"), Path.join(context.project, "mix.lock"))

    File.write!(Path.join(context.project, "test/kept_deps_target_test.exs"), """
    defmodule KeptDepsTargetTest do
      use ExUnit.Case
      test "f", do: assert(KeptDepsTarget.f(1) == #{expected})
    end
    """)
  end

  defp write_dep(dir, version, value) do
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule KeptDep.MixProject do
      use Mix.Project
      def project, do: [app: :kept_dep, version: #{inspect(version)}, elixir: "~> 1.15"]
      def application, do: []
    end
    """)

    File.write!(Path.join(dir, "lib/kept_dep.ex"), """
    defmodule KeptDep do
      def value, do: #{value}
    end
    """)
  end

  defp commit!(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", message])
  end

  defp git!(dir, args) do
    assert {_out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
  end

  defp mix!(project, args) do
    assert {out, 0} =
             System.cmd("mix", args,
               cd: project,
               env: [{"MIX_ENV", "test"}],
               stderr_to_stdout: true
             )

    out
  end
end
