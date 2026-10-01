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
    refute Deps.has_dep?(igniter, :mutare_plug)
    refute Deps.has_dep?(igniter, :mutare_phoenix)
    refute Deps.has_dep?(igniter, :mutare_phoenix_live_view)
    refute Deps.has_dep?(igniter, :mutare_ecto)
    refute Deps.has_dep?(igniter, :mutare_oban)
    refute Deps.has_dep?(igniter, :mutare_decimal)
    refute Deps.has_dep?(igniter, :mutare_swoosh)
    refute Deps.has_dep?(igniter, :mutare_phoenix_swoosh)
    refute Deps.has_dep?(igniter, :mutare_gettext)

    content = config(igniter)
    refute content =~ "Mutare.Plug"
    refute content =~ "Mutare.Phoenix"
    refute content =~ "Mutare.Ecto"
    refute content =~ "Mutare.Oban"
    refute content =~ "Mutare.Decimal"
    refute content =~ "Mutare.Swoosh"
    refute content =~ "Mutare.Gettext"
    # The active config is the empty list (defaults); guidance lives in comments.
    assert content =~ "[]"
  end

  # --- plug (a mutator package) --------------------------------------------

  test "plug: adds mutare_plug and splices its preset into :mutators" do
    igniter = project([{:plug, "~> 1.16"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_plug)
    refute Deps.has_dep?(igniter, :mutare_phoenix)

    content = config(igniter)
    assert content =~ "[:builtins] ++ Mutare.Plug.all()"
    # Plug contributes no extension, so no :extensions key is written.
    refute content =~ "extensions:"
  end

  test "a Plug server alone (bandit or plug_cowboy) is enough to wire up mutare_plug" do
    # A Plug-only app may declare just its server and pull :plug in transitively.
    for server <- [{:bandit, "~> 1.5"}, {:plug_cowboy, "~> 2.7"}] do
      igniter = project([server]) |> install()

      assert Deps.has_dep?(igniter, :mutare_plug)
      refute Deps.has_dep?(igniter, :mutare_phoenix)
      assert config(igniter) =~ "Mutare.Plug.all()"
    end
  end

  test "plug dep is dev/test-only and runtime: false" do
    igniter = project([{:plug, "~> 1.16"}]) |> install()

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare_plug)
    assert declaration =~ ~s({:mutare_plug, ">= 0.0.0")
    assert declaration =~ "only: [:dev, :test]"
    assert declaration =~ "runtime: false"
  end

  # --- phoenix -------------------------------------------------------------

  test "phoenix alone wires up mutare_plug and mutare_phoenix, and lists the extension" do
    # A Phoenix app declares :phoenix and pulls :plug in transitively, so the one declared
    # signal composes both presets — and Mutare.Phoenix joins :extensions for its routing.
    igniter = project([{:phoenix, "~> 1.7"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_plug)
    assert Deps.has_dep?(igniter, :mutare_phoenix)
    refute Deps.has_dep?(igniter, :mutare_phoenix_live_view)
    refute Deps.has_dep?(igniter, :mutare_ecto)

    content = config(igniter)
    assert content =~ "[:builtins] ++ Mutare.Plug.all() ++ Mutare.Phoenix.all()"
    assert content =~ "extensions: [Mutare.Phoenix]"
  end

  test "plug + phoenix declared together adds each package once" do
    igniter = project([{:plug, "~> 1.16"}, {:phoenix, "~> 1.7"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_plug)
    assert Deps.has_dep?(igniter, :mutare_phoenix)

    assert config(igniter) =~ "Mutare.Plug.all() ++ Mutare.Phoenix.all()"
  end

  test "phoenix + live_view: adds all three companion packages and composes the presets" do
    igniter = project([{:phoenix, "~> 1.7"}, {:phoenix_live_view, "~> 1.0"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_plug)
    assert Deps.has_dep?(igniter, :mutare_phoenix)
    assert Deps.has_dep?(igniter, :mutare_phoenix_live_view)

    content = config(igniter)
    assert content =~ "Mutare.Plug.all()"
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

  # --- swoosh / phoenix_swoosh (mutator packages) --------------------------

  test "swoosh: adds mutare_swoosh and splices its preset into :mutators" do
    igniter = project([{:swoosh, "~> 1.16"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_swoosh)
    refute Deps.has_dep?(igniter, :mutare_phoenix_swoosh)
    refute Deps.has_dep?(igniter, :mutare_phoenix)

    content = config(igniter)
    assert content =~ "[:builtins] ++ Mutare.Swoosh.all()"
    refute content =~ "Mutare.Phoenix.Swoosh.all()"
  end

  test "phoenix_swoosh alone wires up both mutare_swoosh and mutare_phoenix_swoosh" do
    # A phoenix_swoosh app builds its emails through Swoosh.Email even when :swoosh is
    # only a transitive dep, so the one declared signal composes both presets.
    igniter = project([{:phoenix_swoosh, "~> 1.2"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_swoosh)
    assert Deps.has_dep?(igniter, :mutare_phoenix_swoosh)

    content = config(igniter)
    assert content =~ "Mutare.Swoosh.all()"
    assert content =~ "Mutare.Phoenix.Swoosh.all()"
  end

  test "swoosh + phoenix_swoosh declared together adds each package once" do
    igniter = project([{:swoosh, "~> 1.16"}, {:phoenix_swoosh, "~> 1.2"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_swoosh)
    assert Deps.has_dep?(igniter, :mutare_phoenix_swoosh)

    content = config(igniter)
    assert content =~ "Mutare.Swoosh.all() ++ Mutare.Phoenix.Swoosh.all()"
  end

  test "swoosh dep is dev/test-only and runtime: false" do
    igniter = project([{:swoosh, "~> 1.16"}]) |> install()

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare_swoosh)
    assert declaration =~ ~s({:mutare_swoosh, ">= 0.0.0")
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
    assert content =~ "Mutare.Plug.all() ++ Mutare.Phoenix.all()"
    assert content =~ "extensions: [Mutare.Phoenix, Mutare.Gettext]"
  end

  test "phoenix_ecto: adds mutare_phoenix_ecto under :extensions beside mutare_ecto" do
    igniter = project([{:phoenix_ecto, "~> 4.6"}]) |> install()

    assert Deps.has_dep?(igniter, :mutare_phoenix_ecto)
    assert Deps.has_dep?(igniter, :mutare_ecto)

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare_phoenix_ecto)
    assert declaration =~ "only: [:dev, :test]"

    content = config(igniter)
    assert content =~ "extensions: [Mutare.Phoenix.Ecto]"
    assert content =~ "{Mutare.Ecto, repo: "
  end

  test "a full Phoenix app lists every extension, in registry order" do
    igniter =
      project([{:phoenix, "~> 1.7"}, {:gettext, "~> 0.26"}, {:phoenix_ecto, "~> 4.6"}])
      |> install()

    assert config(igniter) =~ "extensions: [Mutare.Phoenix, Mutare.Gettext, Mutare.Phoenix.Ecto]"
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

    assert Deps.has_dep?(igniter, :mutare_plug)
    assert Deps.has_dep?(igniter, :mutare_phoenix)
    assert Deps.has_dep?(igniter, :mutare_phoenix_live_view)
    assert Deps.has_dep?(igniter, :mutare_ecto)
    assert Deps.has_dep?(igniter, :mutare_decimal)

    content = config(igniter)
    assert content =~ ":builtins"
    assert content =~ "Mutare.Plug.all()"
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

  test "every companion package is added when its framework is detected" do
    frameworks = [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:ecto_sql, "~> 3.12"},
      {:oban, "~> 2.18"},
      {:decimal, "~> 2.1"},
      {:phoenix_swoosh, "~> 1.2"},
      {:gettext, "~> 0.26"},
      {:phoenix_ecto, "~> 4.6"}
    ]

    igniter = project(frameworks) |> install(["--repo", "MyApp.Repo"])

    for {_framework, package} <- Mutare.Install.companions() do
      assert Deps.has_dep?(igniter, package), "#{package} was not added"
    end
  end

  # --- the :mutare line igniter wrote --------------------------------------

  # What `mix igniter.install mutare` writes for this build: igniter's general requirement.
  defp igniter_written_mutare do
    general =
      Igniter.Util.Version.version_string_to_general_requirement!(Mutare.Install.version())

    {:mutare, general, only: [:dev, :test], runtime: false}
  end

  test "narrows igniter's general :mutare requirement to the suggested one" do
    {_, general, _} = mutare = igniter_written_mutare()
    # On 0.x they differ; were they equal the narrowing would have nothing to show.
    assert general != Mutare.Install.requirement()

    igniter = project([mutare]) |> install()

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare)
    assert declaration =~ ~s({:mutare, "#{Mutare.Install.requirement()}")
    assert declaration =~ "only: [:dev, :test]"
    assert declaration =~ "runtime: false"
  end

  test "leaves any other :mutare requirement alone" do
    igniter = project([{:mutare, "== 0.4.1", only: :test}]) |> install()

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare)
    assert declaration =~ ~s({:mutare, "== 0.4.1")
  end

  test "leaves igniter's requirement alone when the options aren't literals" do
    {_, general, _} = igniter_written_mutare()

    igniter =
      test_project(
        files: %{
          "mix.exs" =>
            mix_exs([]) |> String.replace("[]", ~s([{:mutare, "#{general}", only: @envs}]))
        }
      )
      |> install()

    assert {:ok, declaration} = Deps.get_dep(igniter, :mutare)
    assert declaration =~ ~s("#{general}")
  end

  # --- existing config is preserved ----------------------------------------

  test "existing .mutare.exs is left untouched; mutators are surfaced as a notice" do
    existing = %{".mutare.exs" => ~s([paths: ["lib"]]\n)}
    igniter = project([{:phoenix, "~> 1.7"}], existing) |> install()

    # The dep is still added…
    assert Deps.has_dep?(igniter, :mutare_phoenix)
    # …but the user's config is preserved and the recommendation printed instead.
    assert_unchanged(igniter, ".mutare.exs")
    assert Enum.any?(igniter.notices, &(&1 =~ "Mutare.Plug.all() ++ Mutare.Phoenix.all()"))
    assert Enum.any?(igniter.notices, &(&1 =~ "extensions: [Mutare.Phoenix]"))
  end

  # --- agent skill via usage_rules -----------------------------------------

  @usage_rules {:usage_rules, "~> 1.2", only: :dev, runtime: false}

  # A mix.exs whose `project/0` carries `project_extra` (keyword entries, as source) and
  # whose module body carries `extra_defs`, for the shapes a usage_rules config takes.
  defp usage_rules_project(project_extra, extra_defs \\ "") do
    mix_exs = """
    defmodule Test.MixProject do
      use Mix.Project

      def project do
        [app: :test, version: "0.1.0", elixir: "~> 1.17", deps: deps()#{project_extra}]
      end

      def application, do: [extra_applications: [:logger]]

      defp deps do
        [#{inspect(@usage_rules)}]
      end
    #{extra_defs}
    end
    """

    # Formatted, as Igniter writes it back, so an edit that changes nothing leaves the file
    # byte-identical and `assert_unchanged/2` can tell.
    formatted = IO.iodata_to_binary([Code.format_string!(mix_exs), "\n"])
    test_project(files: %{"mix.exs" => formatted})
  end

  defp mix_exs_content(igniter) do
    igniter.rewrite |> Rewrite.source!("mix.exs") |> Rewrite.Source.get(:content)
  end

  defp sync_notice?(igniter), do: Enum.any?(igniter.notices, &(&1 =~ "mix usage_rules.sync"))

  test "without usage_rules, mix.exs gets no usage_rules config" do
    igniter = project([]) |> install()

    refute mix_exs_content(igniter) =~ "usage_rules"
    refute sync_notice?(igniter)
  end

  test "usage_rules with no config: creates the nested key and lists :mutare" do
    igniter = usage_rules_project("") |> install()

    assert mix_exs_content(igniter) =~
             ~r/usage_rules:\s*\[\s*skills:\s*\[\s*package_skills:\s*\[:mutare\]\s*\]\s*\]/

    assert sync_notice?(igniter)
  end

  test "usage_rules with other package skills: appends :mutare and keeps the rest" do
    igniter =
      usage_rules_project(
        ~s(, usage_rules: [file: "AGENTS.md", skills: [package_skills: [:ash]]])
      )
      |> install()

    content = mix_exs_content(igniter)
    assert content =~ ~r/package_skills:\s*\[:ash,\s*:mutare\]/
    assert content =~ ~s(file: "AGENTS.md")
    assert sync_notice?(igniter)
  end

  test "usage_rules already listing :mutare: mix.exs is unchanged" do
    igniter =
      usage_rules_project(", usage_rules: [skills: [package_skills: [:mutare]]]") |> install()

    assert_unchanged(igniter, "mix.exs")
  end

  test "usage_rules config in a private function: :mutare is added there" do
    igniter =
      usage_rules_project(
        ", usage_rules: usage_rules()",
        "  defp usage_rules, do: [skills: [package_skills: [:ash]]]"
      )
      |> install()

    content = mix_exs_content(igniter)
    assert content =~ "usage_rules: usage_rules()"
    assert content =~ ~r/package_skills:\s*\[:ash,\s*:mutare\]/
  end

  test "package_skills that is not a list literal: warns instead of editing" do
    igniter =
      usage_rules_project(", usage_rules: [skills: [package_skills: Enum.concat([:ash], [])]]")
      |> install()

    assert_unchanged(igniter, "mix.exs")
    assert_has_warning(igniter, &(&1 =~ "not a keyword list the installer can edit"))
    refute sync_notice?(igniter)
  end

  test "usage_rules config the installer cannot walk: warns, and the install still applies" do
    igniter =
      usage_rules_project(", usage_rules: MyApp.Rules.config()")
      |> install()

    assert_unchanged(igniter, "mix.exs")
    assert_has_warning(igniter, &(&1 =~ "not a keyword list the installer can edit"))
    assert Rewrite.Source.issues(Rewrite.source!(igniter.rewrite, "mix.exs")) == []
    assert_creates(igniter, ".mutare.exs")
    refute sync_notice?(igniter)
  end
end
