defmodule Mix.Tasks.Mutare.InstallTest do
  # Exercises the igniter installer end to end with in-memory test projects: each case
  # builds a `mix.exs` with a particular dependency set, runs `mutare.install`, and asserts
  # on the deps added and the `.mutare.exs` written. No files touch disk (`Igniter.Test`
  # keeps everything in the in-memory rewrite), so this is fast and hermetic.
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Igniter.Project.Deps

  # --- helpers -------------------------------------------------------------

  defp project(deps, extra_files \\ %{}) do
    files = Map.put(extra_files, "mix.exs", mix_exs(deps))
    test_project(files: files)
  end

  defp mix_exs(deps) do
    dep_list = Enum.map_join(deps, ", ", &inspect/1)

    """
    defmodule Test.MixProject do
      use Mix.Project

      def project do
        [app: :test, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
      end

      def application, do: [extra_applications: [:logger]]

      defp deps do
        [#{dep_list}]
      end
    end
    """
  end

  defp install(igniter, argv \\ []), do: Igniter.compose_task(igniter, "mutare.install", argv)

  defp config(igniter) do
    igniter.rewrite |> Rewrite.source!(".mutare.exs") |> Rewrite.Source.get(:content)
  end

  @repo """
  defmodule MyApp.Repo do
    use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres
  end
  """

  # --- nothing detected ----------------------------------------------------

  test "no frameworks: creates a starter .mutare.exs and adds no companion packages" do
    igniter = project([]) |> install()

    assert_creates(igniter, ".mutare.exs")
    refute Deps.has_dep?(igniter, :mutare_phoenix)
    refute Deps.has_dep?(igniter, :mutare_phoenix_live_view)
    refute Deps.has_dep?(igniter, :mutare_ecto)
    refute Deps.has_dep?(igniter, :mutare_oban)
    refute Deps.has_dep?(igniter, :mutare_decimal)
    refute Deps.has_dep?(igniter, :mutare_gettext)

    content = config(igniter)
    refute content =~ "Mutare.Phoenix"
    refute content =~ "Mutare.Ecto"
    refute content =~ "Mutare.Oban"
    refute content =~ "Mutare.Decimal"
    refute content =~ "Mutare.Gettext"
    # The active config is the empty list (defaults); guidance lives in comments.
    assert content =~ "[]"
  end

  # --- phoenix -------------------------------------------------------------

  test "phoenix: adds mutare_phoenix and enables its preset" do
    igniter = project([{:phoenix, "~> 1.7"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_phoenix)
    refute Deps.has_dep?(igniter, :mutare_phoenix_live_view)
    refute Deps.has_dep?(igniter, :mutare_ecto)

    assert config(igniter) =~ "[:builtins] ++ Mutare.Phoenix.all()"
  end

  test "phoenix + live_view: adds both companion packages and composes both presets" do
    igniter = project([{:phoenix, "~> 1.7"}, {:phoenix_live_view, "~> 1.0"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_phoenix)
    assert Deps.has_dep?(igniter, :mutare_phoenix_live_view)

    content = config(igniter)
    assert content =~ "Mutare.Phoenix.all()"
    assert content =~ "Mutare.Phoenix.LiveView.all()"
  end

  # --- ecto ----------------------------------------------------------------

  test "ecto via --repo: configures mutare_ecto with the given repo" do
    igniter = project([{:ecto_sql, "~> 3.10"}]) |> install(["--repo", "MyApp.Repo"])

    assert Deps.has_dep?(igniter, :mutare_ecto)
    assert config(igniter) =~ "{Mutare.Ecto, repo: MyApp.Repo}"
  end

  test "ecto with a single repo in the project: auto-detects it" do
    igniter = project([{:ecto_sql, "~> 3.10"}], %{"lib/repo.ex" => @repo}) |> install()

    assert config(igniter) =~ "{Mutare.Ecto, repo: MyApp.Repo}"
  end

  test "ecto with no detectable repo: writes a placeholder and warns" do
    igniter = project([{:ecto, "~> 3.10"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_ecto)
    assert config(igniter) =~ "{Mutare.Ecto, repo: YourApp.Repo}"
    assert_has_warning(igniter, &(&1 =~ "Could not find an Ecto repo"))
  end

  # --- oban (a mutator package) --------------------------------------------

  test "oban: adds mutare_oban and splices its preset into :mutators" do
    igniter = project([{:oban, "~> 2.17"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_oban)
    refute Deps.has_dep?(igniter, :mutare_phoenix)

    assert config(igniter) =~ "[:builtins] ++ Mutare.Oban.all()"
  end

  test "oban_pro alone is enough to wire up mutare_oban" do
    igniter = project([{:oban_pro, "~> 1.4"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_oban)
    assert config(igniter) =~ "Mutare.Oban.all()"
  end

  test "oban + ecto: composes the Ecto config and the Oban preset" do
    igniter =
      project([{:ecto_sql, "~> 3.10"}, {:oban, "~> 2.17"}], %{"lib/repo.ex" => @repo})
      |> install()

    assert Deps.has_dep?(igniter, :mutare_ecto)
    assert Deps.has_dep?(igniter, :mutare_oban)

    content = config(igniter)
    assert content =~ "{Mutare.Ecto, repo: MyApp.Repo}"
    assert content =~ "Mutare.Oban.all()"
  end

  test "oban dep is dev/test-only and runtime: false" do
    igniter = project([{:oban, "~> 2.17"}]) |> install()

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare_oban)
    assert declaration =~ ~s({:mutare_oban, ">= 0.0.0")
    assert declaration =~ "only: [:dev, :test]"
    assert declaration =~ "runtime: false"
  end

  # --- decimal (a mutator package) -----------------------------------------

  test "decimal: adds mutare_decimal and splices its preset into :mutators" do
    igniter = project([{:decimal, "~> 2.0"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_decimal)
    refute Deps.has_dep?(igniter, :mutare_phoenix)
    refute Deps.has_dep?(igniter, :mutare_ecto)

    assert config(igniter) =~ "[:builtins] ++ Mutare.Decimal.all()"
  end

  test "decimal + oban: composes both mutator presets" do
    igniter = project([{:decimal, "~> 2.0"}, {:oban, "~> 2.17"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_decimal)
    assert Deps.has_dep?(igniter, :mutare_oban)

    content = config(igniter)
    assert content =~ "Mutare.Oban.all()"
    assert content =~ "Mutare.Decimal.all()"
  end

  test "decimal dep is dev/test-only and runtime: false" do
    igniter = project([{:decimal, "~> 2.0"}]) |> install()

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare_decimal)
    assert declaration =~ ~s({:mutare_decimal, ">= 0.0.0")
    assert declaration =~ "only: [:dev, :test]"
    assert declaration =~ "runtime: false"
  end

  # --- gettext (an extension, not a mutator) -----------------------------------

  test "gettext: adds mutare_gettext and lists it under :extensions" do
    igniter = project([{:gettext, "~> 0.26"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_gettext)
    refute Deps.has_dep?(igniter, :mutare_phoenix)
    refute Deps.has_dep?(igniter, :mutare_ecto)

    content = config(igniter)
    assert content =~ "extensions: [Mutare.Gettext]"
    # Gettext contributes no mutator families, so no :mutators key is written.
    refute content =~ "mutators:"
  end

  test "gettext + phoenix: composes both a :mutators and a :extensions key" do
    igniter = project([{:phoenix, "~> 1.7"}, {:gettext, "~> 0.26"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_phoenix)
    assert Deps.has_dep?(igniter, :mutare_gettext)

    content = config(igniter)
    assert content =~ "Mutare.Phoenix.all()"
    assert content =~ "extensions: [Mutare.Gettext]"
  end

  test "gettext dep is dev/test-only and runtime: false" do
    igniter = project([{:gettext, "~> 0.26"}]) |> install()

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare_gettext)
    assert declaration =~ ~s({:mutare_gettext, ">= 0.0.0")
    assert declaration =~ "only: [:dev, :test]"
    assert declaration =~ "runtime: false"
  end

  test "existing .mutare.exs with gettext: dep added, file untouched, :extensions surfaced" do
    existing = %{".mutare.exs" => ~s([paths: ["lib"]]\n)}
    igniter = project([{:gettext, "~> 0.26"}], existing) |> install()

    assert Deps.has_dep?(igniter, :mutare_gettext)
    assert_unchanged(igniter, ".mutare.exs")
    assert Enum.any?(igniter.notices, &(&1 =~ "extensions: [Mutare.Gettext]"))
  end

  # --- full stack ----------------------------------------------------------

  test "phoenix + live_view + ecto + decimal: all deps and a composed :mutators" do
    deps = [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:ecto_sql, "~> 3.10"},
      {:decimal, "~> 2.0"}
    ]

    igniter = project(deps, %{"lib/repo.ex" => @repo}) |> install()

    assert Deps.has_dep?(igniter, :mutare_phoenix)
    assert Deps.has_dep?(igniter, :mutare_phoenix_live_view)
    assert Deps.has_dep?(igniter, :mutare_ecto)
    assert Deps.has_dep?(igniter, :mutare_decimal)

    content = config(igniter)
    assert content =~ ":builtins"
    assert content =~ "{Mutare.Ecto, repo: MyApp.Repo}"
    assert content =~ "Mutare.Phoenix.all()"
    assert content =~ "Mutare.Phoenix.LiveView.all()"
    assert content =~ "Mutare.Decimal.all()"
  end

  # --- the dep options it sets ---------------------------------------------

  test "companion deps are dev/test-only and runtime: false" do
    igniter = project([{:phoenix, "~> 1.7"}]) |> install()

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare_phoenix)
    assert declaration =~ ~s({:mutare_phoenix, ">= 0.0.0")
    assert declaration =~ "only: [:dev, :test]"
    assert declaration =~ "runtime: false"
  end

  # --- existing config is preserved ----------------------------------------

  test "existing .mutare.exs is left untouched; mutators are surfaced as a notice" do
    existing = %{".mutare.exs" => ~s([paths: ["lib"]]\n)}
    igniter = project([{:phoenix, "~> 1.7"}], existing) |> install()

    # The dep is still added…
    assert Deps.has_dep?(igniter, :mutare_phoenix)
    # …but the user's config is preserved and the recommendation printed instead.
    assert_unchanged(igniter, ".mutare.exs")
    assert Enum.any?(igniter.notices, &(&1 =~ "Mutare.Phoenix.all()"))
  end
end
