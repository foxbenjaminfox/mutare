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

    test "a real app that merely starts like the generated support app is kept" do
      %{umbrella: umbrella} =
        Umbrella.build(:prefixed, %{
          core: %{files: %{"lib/core.ex" => "defmodule Core do\nend\n"}},
          mutare_support_api: %{
            files: %{"lib/api.ex" => "defmodule Api do\nend\n"}
          }
        })

      resolved = Project.resolve(umbrella)

      assert app_names(resolved.apps) == [:core, :mutare_support_api]
      assert app_names(resolved.mutate_scope) == [:core, :mutare_support_api]
    end

    test "a real app named exactly like the generated support app is kept too" do
      %{umbrella: umbrella} =
        Umbrella.build(:exact, %{
          core: %{files: %{"lib/core.ex" => "defmodule Core do\nend\n"}},
          mutare_support: %{files: %{"lib/support.ex" => "defmodule Support do\nend\n"}}
        })

      resolved = Project.resolve(umbrella)

      assert app_names(resolved.apps) == [:core, :mutare_support]
      assert app_names(resolved.mutate_scope) == [:core, :mutare_support]
    end

    test "an unknown --app raises" do
      %{umbrella: umbrella} = demo_umbrella()

      assert_raise ArgumentError, ~r/no umbrella apps match/, fn ->
        Project.resolve(umbrella, apps: ["nope"])
      end
    end

    test "a partially-valid --app raises rather than silently narrowing" do
      %{umbrella: umbrella} = demo_umbrella()

      assert_raise ArgumentError, ~r/no umbrella apps match \["nope"\]/, fn ->
        Project.resolve(umbrella, apps: ["core", "nope"])
      end
    end
  end

  describe "umbrella_root?/1 — static mix.exs detection" do
    defp root_with_mix_exs(mix_exs_source) do
      dir = Mutare.Test.Project.tmp_dir(:umbrella_root)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
      File.mkdir_p!(Path.join(dir, "apps"))
      File.write!(Path.join(dir, "mix.exs"), mix_exs_source)
      dir
    end

    test "detects apps_path: in the project keyword list" do
      dir =
        root_with_mix_exs("""
        defmodule U.MixProject do
          use Mix.Project
          def project, do: [apps_path: "apps", version: "0.1.0"]
        end
        """)

      assert Project.umbrella_root?(dir)
    end

    test "ignores apps_path: mentioned only in comments or strings" do
      dir =
        root_with_mix_exs("""
        defmodule S.MixProject do
          use Mix.Project
          # not an umbrella; do not add apps_path: here
          @note "apps_path: is deliberately absent"
          def project, do: [app: :s, version: "0.1.0", note: @note]
        end
        """)

      refute Project.umbrella_root?(dir)
    end

    test "an unparsable or missing mix.exs is not an umbrella root" do
      refute Project.umbrella_root?(root_with_mix_exs("def project, do: ["))

      dir = Mutare.Test.Project.tmp_dir(:no_mix_exs)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
      File.mkdir_p!(Path.join(dir, "apps"))
      refute Project.umbrella_root?(dir)
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

  describe "app_test_scopes/3 — narrowing by the declared dependency graph" do
    # core <- web (web depends on core); solo is independent.
    @graph %{core: [], web: [:core], solo: []}

    defp scoped_sandbox(apps) do
      sandbox = Mutare.Test.Project.tmp_dir(:scopes)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(sandbox) end)
      for app <- apps, do: File.mkdir_p!(Path.join([sandbox, "apps", to_string(app), "test"]))
      sandbox
    end

    defp project(scope) do
      apps = for a <- [:core, :web, :solo], do: %{app: a, dir: "apps/#{a}"}
      mutate = for a <- scope, do: %{app: a, dir: "apps/#{a}"}
      %Project{umbrella?: true, copy_root: "u", apps: apps, mutate_scope: mutate}
    end

    test "scopes a mutant to its owning app plus its dependents" do
      sandbox = scoped_sandbox([:core, :web, :solo])

      scopes = Project.app_test_scopes(project([:core]), sandbox, @graph)

      # web depends on core, so it can kill a core mutant; solo cannot and is excluded.
      assert scopes == %{core: ["apps/core/test", "apps/web/test"]}
    end

    test "dependents are followed transitively" do
      sandbox = scoped_sandbox([:core, :web, :solo])
      # core <- web <- solo: solo reaches core's code through web.
      graph = %{core: [], web: [:core], solo: [:web]}

      assert Project.app_test_scopes(project([:core]), sandbox, graph) ==
               %{core: ["apps/core/test", "apps/solo/test", "apps/web/test"]}
    end

    test "an independent app scopes to itself only" do
      sandbox = scoped_sandbox([:core, :web, :solo])

      scopes = Project.app_test_scopes(project([:solo]), sandbox, @graph)
      assert scopes == %{solo: ["apps/solo/test"]}
    end

    test "nodes and edges outside the umbrella (Hex packages) are ignored" do
      sandbox = scoped_sandbox([:core, :web, :solo])
      graph = %{core: [:jason], web: [:core, :plug], solo: [], jason: [], mutare_support: []}

      assert Project.app_test_scopes(project([:core]), sandbox, graph) ==
               %{core: ["apps/core/test", "apps/web/test"]}
    end

    test "an app without a test dir contributes no path" do
      sandbox = scoped_sandbox([:core, :solo])

      assert Project.app_test_scopes(project([:core]), sandbox, @graph) ==
               %{core: ["apps/core/test"]}
    end

    test "degrades to no narrowing (%{}) when the graph lacks an umbrella app" do
      sandbox = scoped_sandbox([:core, :web, :solo])

      # web's node is missing: its dependents are unknown, so nothing may be narrowed.
      assert Project.app_test_scopes(project([:core]), sandbox, %{core: [], solo: []}) == %{}
    end

    test "a single (non-umbrella) project has no scopes" do
      assert Project.app_test_scopes(%Project{umbrella?: false}, "x", %{}) == %{}
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
