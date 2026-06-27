defmodule Mutare.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/foxbenjaminfox/mutare"

  # Internal modules deliberately kept `@moduledoc false`: the transform pipeline's
  # stages (documented as one unit on `Mutare.Transform`) and a few plumbing modules.
  # Public moduledocs still name them in prose — the references are worth keeping in
  # source — so rather than delete the links we tell ExDoc not to autolink to them
  # (they have no doc page), which also silences the "references X but it is hidden"
  # warnings. Matched as a prefix, so a member/type/submodule reference
  # (`Mutare.Mutator.Dispatch.mutations/3`, `Mutare.Transform.Uses.Harvest`) is covered
  # by its parent's entry. Add a module here when a new `@moduledoc false` module gets
  # referenced from a visible moduledoc (the warning tells you which).
  @hidden_internal_modules ~w(
    Mutare.Transform.Resolve
    Mutare.Transform.Uses
    Mutare.Transform.Behaviours
    Mutare.Transform.Analyze
    Mutare.Transform.FunctionPlan
    Mutare.Transform.ModulePlan
    Mutare.Transform.Aliases
    Mutare.Transform.Candidate
    Mutare.Transform.SelectorEmit
    Mutare.Transform.LiftedEmit
    Mutare.Transform.CaseClauseEmit
    Mutare.Transform.ImportWitness
    Mutare.Transform.HostedEmit
    Mutare.Transform.GuardBuild
    Mutare.Transform.ClauseAST
    Mutare.Transform.BindingEscapeEmit
    Mutare.Options.Registry
    Mutare.Mutator.Dispatch
    Mutare.Coverage.HelperTemplate
    Mutare.Ignore.Directive
  )

  # A couple of *typespecs* in visible modules reference a hidden internal type
  # (`Mutare.Schema.t`'s `ineffective_ignores` field uses `Mutare.Ignore.Directive.t`;
  # `Mutare.Transform.Calls`'s `module_key` re-exports `Mutare.Transform.Aliases.module_key`).
  # Typespec autolinking bypasses `:skip_code_autolink_to`, so those are silenced by the
  # *referencing* module instead — keep this list tight.
  @typespec_refs_to_hidden ~w(Mutare.Transform.Calls Mutare.Schema)

  def project do
    [
      app: :mutare,
      version: @version,
      elixir: "~> 1.18",
      description: description(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "A compile-once mutation testing tool for Elixir."
  end

  defp package do
    [
      maintainers: ["Benjamin Fox"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # Hex's default file set already includes LICENSE*, README*, mix.exs,
      # and lib/; list it explicitly so the bundled demo projects don't slip
      # into the package while keeping the licence and docs in.
      files: ["lib", "mix.exs", "README.md", "LICENSE"]
    ]
  end

  defp deps do
    [
      {:sourceror, "~> 1.12"},
      # Powers the `mix mutare.install` / `mix igniter.install mutare` generator
      # (see `Mix.Tasks.Mutare.Install`). Optional so it isn't forced on projects
      # that add Mutare by hand — the installer module is compiled away when absent
      # (`Code.ensure_loaded?(Igniter)` guard) — while still being fetched here so
      # the task compiles and is tested. A consumer who runs `mix igniter.install`
      # already has it.
      {:igniter, "~> 0.8", optional: true},
      {:propcheck, "~> 1.5", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "LICENSE"],
      skip_code_autolink_to: &skip_autolink_to?/1,
      skip_undefined_reference_warnings_on: &(&1 in @typespec_refs_to_hidden),
      # Modules fall into the first group whose entry matches, so the explicit
      # lists win over the trailing catch-alls. "Internal" (`~r//`) sweeps up
      # everything else — the transform pipeline, sandbox, coverage plumbing, etc.
      # `@moduledoc false` modules never appear at all.
      groups_for_modules: [
        "Core API": [
          Mutare,
          Mix.Tasks.Mutare,
          Mutare.Ignore,
          Mutare.Runner,
          Mutare.Options,
          Mutare.Result,
          Mutare.Site
        ],
        "Writing mutators": [
          Mutare.Mutator,
          Mutare.Mutator.Spec,
          Mutare.AST,
          Mutare.Test,
          Mutare.Transform.Calls,
          Mutare.Macros,
          Mutare.Macro.Spec
        ],
        "Built-in mutators": ~r/^Mutare\.Mutators/,
        Reporters: [
          Mutare.Report,
          Mutare.Report.Json,
          Mutare.Report.Html,
          Mutare.Report.Sarif,
          Mutare.Report.Live
        ],
        Internal: ~r//
      ]
    ]
  end

  # True when `ref` (a prose autolink target) names one of the deliberately-hidden
  # internal modules — the module itself, or any member/type/submodule under it.
  defp skip_autolink_to?(ref) do
    bare = ref |> String.replace_prefix("t:", "") |> String.replace_prefix("c:", "")

    Enum.any?(@hidden_internal_modules, fn mod ->
      bare == mod or String.starts_with?(bare, mod <> ".")
    end)
  end

  defp dialyzer do
    [
      # Keep the PLTs in a stable, cacheable location (e.g. for CI).
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit],
      # High-signal spec-accuracy checks on top of the defaults. `:unmatched_returns`
      # is intentionally left off: it fights idiomatic fire-and-forget side-effect
      # calls (File.rm/1, etc.) with no genuine bugs to show for it here.
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  defp aliases do
    [
      check: ["format --check-formatted", "credo", "dialyzer"]
    ]
  end
end
