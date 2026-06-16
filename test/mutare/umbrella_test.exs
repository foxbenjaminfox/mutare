defmodule Mutare.UmbrellaTest do
  @moduledoc """
  End-to-end umbrella coverage: generate a two-app umbrella (web depends on core,
  with a cross-app test), run mutation testing against it with real `mix test`
  subprocesses, and prove the umbrella loop — copy the whole umbrella, mutate the
  scoped apps, classify, and report survivors with `apps/<app>/...` paths.
  """
  use ExUnit.Case, async: false

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
end
