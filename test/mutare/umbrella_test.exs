defmodule Mutare.UmbrellaTest do
  @moduledoc """
  End-to-end umbrella coverage: generate a two-app umbrella (web depends on core,
  with a cross-app test), run mutation testing against it with real `mix test`
  subprocesses, and prove the umbrella loop — copy the whole umbrella, mutate the
  scoped apps, classify, and report survivors with `apps/<app>/...` paths.
  """
  use ExUnit.Case, async: false

  import Mutare.Test.ExUnitSummary, only: [tests_run: 1]

  alias Mutare.Test.Umbrella

  # Pin to arithmetic swaps: the fixture's sites are `+` (core) and `*` (web), so
  # the counts stay small and deterministic across both apps.
  @probe [Mutare.Mutators.Arithmetic]

  @moduletag :runner
  # Several `mix` subprocesses against a full umbrella (compile + baseline +
  # probe + one per mutant).
  @moduletag timeout: 240_000

  setup do
    Umbrella.build(:calc_umbrella, %{
      core: %{
        files: %{
          "lib/core.ex" => """
          defmodule Core do
            def add(a, b), do: a + b
          end
          """,
          "test/core_test.exs" => """
          defmodule CoreTest do
            use ExUnit.Case
            test "add", do: assert(Core.add(2, 3) == 5)
          end
          """
        }
      },
      web: %{
        deps: [:core],
        files: %{
          "lib/web.ex" => """
          defmodule Web do
            def total(a, b), do: Core.add(a, b) * 2
          end
          """,
          "test/web_test.exs" => """
          defmodule WebTest do
            use ExUnit.Case
            # Cross-app: exercises Core.add through Web.
            test "total", do: assert(Web.total(2, 3) == 10)
          end
          """
        }
      }
    })
  end

  test "discovers and mutates sources across umbrella apps", %{
    umbrella: umbrella,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(umbrella, sandbox: sandbox, mutators: @probe)

    files = run.results |> Enum.map(& &1.site.file) |> Enum.uniq()
    assert "apps/core/lib/core.ex" in files
    assert "apps/web/lib/web.ex" in files

    # Mutant locations are root-relative to the umbrella, under each app's lib/.
    assert Enum.all?(run.results, &String.starts_with?(&1.site.file, "apps/"))
  end

  test "the selector activates per app: every mutant is killed", %{
    umbrella: umbrella,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(umbrella, sandbox: sandbox, mutators: @probe)

    # The fixture's tests pin every site (core's `+`, web's `*`), so a working
    # per-app selector kills them all. A false survivor here means the bootstrap
    # did not activate in some app — the catastrophic umbrella failure mode.
    refute run.results == []

    assert Enum.all?(run.results, &(&1.status == :killed)),
           "unexpected non-kills: #{inspect(Enum.reject(run.results, &(&1.status == :killed)) |> Enum.map(&{&1.site.file, &1.status}))}"
  end

  test "the metamutant build is warning-clean and compiles once", %{
    umbrella: umbrella,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(umbrella, sandbox: sandbox, mutators: @probe)
    assert [_ | _] = run.results

    # The coverage helper (`:mutare_cov`) lives in a generated sibling app the
    # mutated apps declare no dep on, so the umbrella may compile a caller before
    # it — an xref "undefined function" warning that mix replays from its manifest
    # on every `mix test` *without* recompiling. `Transform`'s per-module
    # `@compile {:no_warn_undefined, …}` silences it. Per-mutant runs reuse the one
    # build, so a clean output proves both properties at once: no warning leaks,
    # and compile-once still holds (no per-mutant recompile).
    for result <- run.results do
      refute result.output =~ "is undefined",
             "undefined-function warning leaked for #{result.site.file}:\n#{result.output}"

      refute result.output =~ "Compiling",
             "per-mutant run recompiled (compile-once broken) for #{result.site.file}:\n#{result.output}"
    end
  end

  test "coverage records root-relative test files and selects per file", %{
    umbrella: umbrella,
    sandbox: sandbox
  } do
    assert {:ok, run} = Mutare.run(umbrella, sandbox: sandbox, mutators: @probe)

    # The probe's dump is keyed by *umbrella-root-relative* test files, not the
    # app-relative paths a per-app cwd would otherwise produce.
    assert {:ok, coverage} = Mutare.Coverage.read_dump(Path.join(sandbox, "mutare_cov.terms"))
    keys = Map.keys(coverage.by_file)
    assert "apps/core/test/core_test.exs" in keys
    assert "apps/web/test/web_test.exs" in keys

    # web's `*` lives only in Web.total, exercised only by web_test.exs — so that
    # mutant runs that one file (1 test), not the whole umbrella suite.
    web = Enum.find(run.results, &(&1.site.file == "apps/web/lib/web.ex"))
    assert web.status == :killed
    assert tests_run(web.output) == 1
  end

  test "a broad (:full) run is narrowed to the owning app + its dependents" do
    # core <- web (web depends on core); solo is independent. A whole-suite-per
    # -mutant (:full) run of a core mutant must touch core + web (the possible
    # killers) but NOT solo — narrowing by the dependency graph, never below it.
    over =
      Mutare.Test.Umbrella.build(:scope_umbrella, %{
        core: %{
          files: %{
            "lib/core.ex" => "defmodule Core do\n  def double(x), do: x * 2\nend\n",
            "test/core_test.exs" => """
            defmodule CoreTest do
              use ExUnit.Case
              test "double", do: assert(Core.double(3) == 6)
            end
            """
          }
        },
        web: %{
          deps: [:core],
          files: %{
            "lib/web.ex" => "defmodule Web do\n  def run(x), do: Core.double(x) + 1\nend\n",
            "test/web_test.exs" => """
            defmodule WebTest do
              use ExUnit.Case
              test "run", do: assert(Web.run(3) == 7)
            end
            """
          }
        },
        solo: %{
          files: %{
            "lib/solo.ex" => "defmodule Solo do\n  def f, do: :ok\nend\n",
            "test/solo_test.exs" => """
            defmodule SoloTest do
              use ExUnit.Case
              test "f", do: assert(Solo.f() == :ok)
            end
            """
          }
        }
      })

    assert {:ok, run} =
             Mutare.run(over.umbrella,
               sandbox: over.sandbox,
               mutators: @probe,
               test_selection: :full,
               project: Mutare.Project.resolve(over.umbrella, apps: ["core"])
             )

    core = Enum.find(run.results, &(&1.site.file == "apps/core/lib/core.ex"))
    assert core.status == :killed
    # The umbrella prints `==> <app>` only for apps it actually runs. core's
    # dependent (web) ran; the independent solo was excluded by the narrowing.
    assert core.output =~ "==> web"
    refute core.output =~ "solo"
  end

  test "a mutant in core is killed only through a cross-app web test" do
    # core has no test of its own here; only WebTest (in a *different* app)
    # exercises Core.double through Web. The mutant must still be killed — proving
    # the selector is live when a sibling app's suite runs the mutated line.
    over =
      Mutare.Test.Umbrella.build(:cross_umbrella, %{
        core: %{
          files: %{"lib/core.ex" => "defmodule Core do\n  def double(x), do: x * 2\nend\n"}
        },
        web: %{
          deps: [:core],
          files: %{
            "lib/web.ex" => "defmodule Web do\n  def run(x), do: Core.double(x)\nend\n",
            "test/web_test.exs" => """
            defmodule WebTest do
              use ExUnit.Case
              test "run", do: assert(Web.run(3) == 6)
            end
            """
          }
        }
      })

    assert {:ok, run} = Mutare.run(over.umbrella, sandbox: over.sandbox, mutators: @probe)

    assert [_ | _] = run.results
    assert Enum.all?(run.results, &(&1.status == :killed))
    assert Enum.all?(run.results, &(&1.site.file == "apps/core/lib/core.ex"))
  end

  test "a runtime: false sibling dep is still a dependent whose tests can kill" do
    # web depends on core with `runtime: false`: Mix omits core from web's compiled
    # `.app` `applications`, yet Web.run calls Core.double and WebTest exercises it.
    # core has no tests of its own, so narrowing this broad (:full) run by the
    # *runtime* graph would run core's empty suite alone and report a false
    # survivor. The declared graph keeps web as a dependent: killed, through web.
    over =
      Mutare.Test.Umbrella.build(:runtime_false_umbrella, %{
        core: %{
          files: %{"lib/core.ex" => "defmodule Core do\n  def double(x), do: x * 2\nend\n"}
        },
        web: %{
          deps: [{:core, runtime: false}],
          files: %{
            "lib/web.ex" => "defmodule Web do\n  def run(x), do: Core.double(x)\nend\n",
            "test/web_test.exs" => """
            defmodule WebTest do
              use ExUnit.Case
              test "run", do: assert(Web.run(3) == 6)
            end
            """
          }
        }
      })

    assert {:ok, run} =
             Mutare.run(over.umbrella,
               sandbox: over.sandbox,
               mutators: @probe,
               test_selection: :full,
               project: Mutare.Project.resolve(over.umbrella, apps: ["core"])
             )

    assert [_ | _] = run.results
    assert Enum.all?(run.results, &(&1.site.file == "apps/core/lib/core.ex"))
    assert Enum.all?(run.results, &(&1.status == :killed))
    assert Enum.all?(run.results, &(&1.output =~ "==> web"))
  end

  test "an application-only sibling is still a dependent whose tests can kill" do
    # web names core only through application/0, so it has no Mix dependency-tree
    # edge. Broad narrowing must still include web when mutating core.
    over =
      Mutare.Test.Umbrella.build(:application_only_umbrella, %{
        core: %{
          files: %{"lib/core.ex" => "defmodule Core do\n  def double(x), do: x * 2\nend\n"}
        },
        web: %{
          application: [extra_applications: [:core]],
          files: %{
            "lib/web.ex" => "defmodule Web do\n  def run(x), do: Core.double(x)\nend\n",
            "test/web_test.exs" => """
            defmodule WebTest do
              use ExUnit.Case
              test "run", do: assert(Web.run(3) == 6)
            end
            """
          }
        }
      })

    assert {:ok, run} =
             Mutare.run(over.umbrella,
               sandbox: over.sandbox,
               mutators: @probe,
               test_selection: :full,
               project: Mutare.Project.resolve(over.umbrella, apps: ["core"])
             )

    assert [_ | _] = run.results
    assert Enum.all?(run.results, &(&1.site.file == "apps/core/lib/core.ex"))
    assert Enum.all?(run.results, &(&1.status == :killed))
    assert Enum.all?(run.results, &(&1.output =~ "==> web"))
  end
end
