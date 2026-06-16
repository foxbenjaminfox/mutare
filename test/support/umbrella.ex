defmodule Mutare.Test.Umbrella do
  @moduledoc """
  Lays down a throwaway **umbrella** target project in a unique temp dir for the
  umbrella `:runner` tests, and registers its cleanup.

  The single-app `Mutare.Test.Project` bakes in a one-`mix.exs`, one-`test_helper`
  shape; an umbrella needs a root `mix.exs` with `apps_path:`, N child `mix.exs`
  (each pointing `build_path`/`config_path`/`deps_path`/`lockfile` up two levels so
  the apps share one build), inter-app `in_umbrella` deps, and a `test_helper.exs`
  per app. This builds that scaffold so each test spells out just the app sources.

  Reuses `Mutare.Test.Project.tmp_dir/1` for the unique base + ExUnit `on_exit`
  cleanup.
  """

  alias Mutare.Test.Project

  @doc """
  Build an umbrella named `name` from `apps` and register its cleanup.

  `apps` is `%{app_atom => spec}` where `spec` is `%{files: %{rel => contents},
  deps: [app_atom]}` — `deps` (other apps it depends on, wired as `in_umbrella`)
  defaults to `[]`, and a `test/test_helper.exs` defaulting to `ExUnit.start()` is
  supplied unless `files` lists one. A root `mix.exs` (`apps_path: "apps"`) and a
  `config/config.exs` are generated automatically.

  Returns `%{base, umbrella, sandbox}` where `umbrella` is ready to hand to
  `Mutare.run/2` and `sandbox` is its scratch dir.
  """
  @spec build(atom(), %{optional(atom()) => map()}) :: %{
          base: Path.t(),
          umbrella: Path.t(),
          sandbox: Path.t()
        }
  def build(name, apps) do
    base = Project.tmp_dir(name)
    umbrella = Path.join(base, to_string(name))
    sandbox = Path.join(base, "sandbox")

    write(umbrella, "mix.exs", root_mix_exs(name))
    write(umbrella, "config/config.exs", "import Config\n")

    Enum.each(apps, fn {app, spec} ->
      app_dir = Path.join("apps", to_string(app))
      write(umbrella, Path.join(app_dir, "mix.exs"), child_mix_exs(app, Map.get(spec, :deps, [])))

      spec
      |> Map.fetch!(:files)
      |> Map.put_new("test/test_helper.exs", "ExUnit.start()\n")
      |> Enum.each(fn {rel, contents} -> write(umbrella, Path.join(app_dir, rel), contents) end)
    end)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, umbrella: umbrella, sandbox: sandbox}
  end

  defp root_mix_exs(name) do
    module = name |> to_string() |> Macro.camelize()

    """
    defmodule #{module}.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0", deps: []]
    end
    """
  end

  defp child_mix_exs(app, deps) do
    module = app |> to_string() |> Macro.camelize()
    deps_list = deps |> Enum.map_join(", ", &"{:#{&1}, in_umbrella: true}")

    """
    defmodule #{module}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app},
          version: "0.1.0",
          build_path: "../../_build",
          config_path: "../../config/config.exs",
          deps_path: "../../deps",
          lockfile: "../../mix.lock",
          elixir: "~> 1.15",
          deps: deps()
        ]
      end

      def application, do: []
      defp deps, do: [#{deps_list}]
    end
    """
  end

  defp write(umbrella, rel, contents) do
    path = Path.join(umbrella, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
