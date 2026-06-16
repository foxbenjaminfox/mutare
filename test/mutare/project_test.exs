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
