defmodule Mutare.DependencyDiagnosticIntegrationTest do
  use ExUnit.Case, async: false

  alias Mutare.Sandbox.Command.Output
  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  test "an external path dep is a dependency failure, not compile-poisoning" do
    token = System.unique_integer([:positive])
    relative_dep = "../outside_dep_#{token}"

    %{base: base, project: project} =
      Project.build(:dependency_target, %{
        "mix.exs" => target_mix_exs(relative_dep),
        "lib/dependency_target.ex" => """
        defmodule DependencyTarget do
          def add(a, b), do: a + b
        end
        """
      })

    outside_dep = Path.join(base, "outside_dep_#{token}")
    File.mkdir_p!(outside_dep)
    File.write!(Path.join(outside_dep, "mix.exs"), dependency_mix_exs())

    # Prove the target itself is healthy: the relative path resolves beside the
    # original project. It becomes unavailable only after the project is copied
    # to Mutare's unrelated temp sandbox — a throwaway one here, so the test
    # leaves nothing behind in the temp dir (a kept default sandbox would persist).
    assert {_output, 0} = Project.compile(project)

    assert {:error, :dependency_failed, detail} =
             Mutare.run(project, keep_sandbox: false, mutators: [Mutare.Mutators.Arithmetic])

    assert Output.dependency_issue(detail) == :unavailable
    assert detail =~ "outside_dep"
    assert detail =~ "the dependency is not available"
  end

  defp target_mix_exs(relative_dep) do
    """
    defmodule DependencyTarget.MixProject do
      use Mix.Project

      def project do
        [
          app: :dependency_target,
          version: "0.1.0",
          elixir: "~> 1.15",
          deps: [{:outside_dep, path: #{inspect(relative_dep)}}]
        ]
      end

      def application, do: []
    end
    """
  end

  defp dependency_mix_exs do
    """
    defmodule OutsideDep.MixProject do
      use Mix.Project
      def project, do: [app: :outside_dep, version: "0.1.0", elixir: "~> 1.15"]
      def application, do: []
    end
    """
  end
end
