defmodule Mutare.ProjectTest do
  use ExUnit.Case, async: false

  alias Mutare.Project
  alias Mutare.Test.Umbrella

  defp demo_umbrella do
    Umbrella.build(:demo, %{
      core: %{files: %{"lib/core.ex" => "defmodule Core do\n  def add(a, b), do: a + b\nend\n"}},
      web: %{
        deps: [:core],
        files: %{
          "lib/web.ex" => "defmodule Web do\n  def total(a, b), do: Core.add(a, b) * 2\nend\n"
        }
      }
    })
  end

  defp app_names(entries), do: entries |> Enum.map(& &1.app) |> Enum.sort()

  describe "resolve/2 — single app" do
    test "a plain project is its own copy-root with a single `.` scope" do
      %{project: project} =
        Mutare.Test.Project.build(:solo, %{"lib/solo.ex" => "defmodule Solo do\nend\n"})

      resolved = Project.resolve(project)

      refute resolved.umbrella?
      assert resolved.copy_root == project
      assert resolved.mutate_scope == [%{app: nil, dir: "."}]
      assert resolved.apps == [%{app: nil, dir: "."}]
    end
  end

  describe "resolve/2 — umbrella root" do
    test "copies the umbrella and mutates every app by default" do
      %{umbrella: umbrella} = demo_umbrella()

      resolved = Project.resolve(umbrella)

      assert resolved.umbrella?
      assert resolved.copy_root == umbrella
      assert app_names(resolved.apps) == [:core, :web]
      assert app_names(resolved.mutate_scope) == [:core, :web]
      assert %{app: :core, dir: "apps/core"} in resolved.apps
    end

    test "--app narrows the mutate-scope but keeps every app in `apps`" do
      %{umbrella: umbrella} = demo_umbrella()

      resolved = Project.resolve(umbrella, apps: ["core"])

      assert app_names(resolved.mutate_scope) == [:core]
      assert app_names(resolved.apps) == [:core, :web]
    end

    test "--workspace mutates every app" do
      %{umbrella: umbrella} = demo_umbrella()

      resolved = Project.resolve(umbrella, workspace: true)
      assert app_names(resolved.mutate_scope) == [:core, :web]
    end

    test "an unknown --app raises" do
      %{umbrella: umbrella} = demo_umbrella()

      assert_raise ArgumentError, ~r/no umbrella apps match/, fn ->
        Project.resolve(umbrella, apps: ["nope"])
      end
    end
  end

  describe "resolve/2 — app target" do
    test "targeting apps/<app> copies the whole umbrella but scopes to that app" do
      %{umbrella: umbrella} = demo_umbrella()

      resolved = Project.resolve(Path.join(umbrella, "apps/core"))

      assert resolved.umbrella?
      assert resolved.copy_root == Path.expand(umbrella)
      assert app_names(resolved.mutate_scope) == [:core]
      assert app_names(resolved.apps) == [:core, :web]
    end
  end

  describe "app_test_scopes/3 — narrowing by the dependency graph" do
    # core <- web (web depends on core); solo is independent.
    defp scoped_sandbox(app_deps) do
      sandbox = Mutare.Test.Project.tmp_dir(:scopes)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(sandbox) end)

      for {app, deps} <- app_deps do
        File.mkdir_p!(Path.join([sandbox, "apps", to_string(app), "test"]))
        ebin = Path.join([sandbox, "_build/test/lib", to_string(app), "ebin"])
        File.mkdir_p!(ebin)
        apps = [:kernel, :stdlib | deps] |> Enum.map_join(", ", &to_string/1)

        File.write!(
          Path.join(ebin, "#{app}.app"),
          "{application, #{app}, [{applications, [#{apps}]}]}.\n"
        )
      end

      sandbox
    end

    defp project(scope) do
      apps = for a <- [:core, :web, :solo], do: %{app: a, dir: "apps/#{a}"}
      mutate = for a <- scope, do: %{app: a, dir: "apps/#{a}"}
      %Project{umbrella?: true, copy_root: "u", apps: apps, mutate_scope: mutate}
    end

    test "scopes a mutant to its owning app plus its (transitive) dependents" do
      sandbox = scoped_sandbox(%{core: [], web: [:core], solo: []})

      scopes = Project.app_test_scopes(project([:core]), sandbox, build_lib(sandbox))

      # web depends on core, so it can kill a core mutant; solo cannot and is excluded.
      assert scopes == %{core: ["apps/core/test", "apps/web/test"]}
    end

    test "an independent app scopes to itself only" do
      sandbox = scoped_sandbox(%{core: [], web: [:core], solo: []})

      scopes = Project.app_test_scopes(project([:solo]), sandbox, build_lib(sandbox))
      assert scopes == %{solo: ["apps/solo/test"]}
    end

    test "degrades to no narrowing (%{}) when a .app cannot be read" do
      sandbox = scoped_sandbox(%{core: [], web: [:core], solo: []})
      File.rm_rf!(Path.join([sandbox, "_build/test/lib/web"]))

      assert Project.app_test_scopes(project([:core]), sandbox, build_lib(sandbox)) == %{}
    end

    test "a single (non-umbrella) project has no scopes" do
      assert Project.app_test_scopes(%Project{umbrella?: false}, "x", "y") == %{}
    end

    defp build_lib(sandbox), do: Path.join(sandbox, "_build/test/lib")
  end

  describe "discovery is scoped to the mutate-scope apps" do
    test "Schema.build finds sources under each app's lib/" do
      %{umbrella: umbrella} = demo_umbrella()

      schema =
        Mutare.Schema.build(umbrella,
          project: Project.resolve(umbrella),
          mutators: [Mutare.Mutators.Arithmetic]
        )

      files = Map.keys(schema.metamutants)
      assert "apps/core/lib/core.ex" in files
      assert "apps/web/lib/web.ex" in files
    end

    test "--app restricts discovery to the chosen app" do
      %{umbrella: umbrella} = demo_umbrella()

      schema =
        Mutare.Schema.build(umbrella,
          project: Project.resolve(umbrella, apps: ["core"]),
          mutators: [Mutare.Mutators.Arithmetic]
        )

      files = Map.keys(schema.metamutants)
      assert "apps/core/lib/core.ex" in files
      refute "apps/web/lib/web.ex" in files
    end
  end
end
