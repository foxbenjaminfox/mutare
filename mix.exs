defmodule Mutare.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/foxbenjaminfox/mutare"

  # Internal modules deliberately kept `@moduledoc false`: the transform pipeline's
  # stages (documented as one unit on `Mutare.Transform`) and a few plumbing modules.
  # Public moduledocs still name them in prose — the references are worth keeping in
  # source — so rather than delete the links we tell ExDoc not to autolink to them
  # (they have no doc page), which also silences the "references X but it is hidden"
  # warnings. Matched as a prefix, so a member/type/submodule reference
  # (`Mutare.Mutator.Dispatch.mutations/3`, `Mutare.Transform.Uses.Harvest`) is covered
  # by its parent's entry. Add a module here when a new `@moduledoc false` module gets
  # referenced from a visible moduledoc (the warning tells you which). Also covers the
  # rare case of a *stdlib* module that's hidden the same way (`Module.ParallelChecker`,
  # named in `Mutare.Sandbox.CompilerOptions` — internal to the Elixir compiler, no doc
  # page of its own).
  @hidden_internal_modules ~w(
    Module.ParallelChecker
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
    Mutare.Transform.Tag
    Mutare.Transform.ClauseAST
    Mutare.Transform.BindingEscapeEmit
    Mutare.Transform.Config
    Mutare.Runner.Hydrate
    Mutare.Options.Registry
    Mutare.CallRouting.Registry
    Mutare.Mutator.Dispatch
    Mutare.Coverage.HelperTemplate
    Mutare.Ignore.Directive
    Mutare.Mutators.RegexLiteral.Tokens
  )

  # A couple of *typespecs* in visible modules reference a hidden internal type
  # (`Mutare.Schema.t`'s `ineffective_ignores` field uses `Mutare.Ignore.Directive.t`;
  # `Mutare.Calls`'s `module_key` re-exports `Mutare.Transform.Calls.module_key`;
  # `Mutare.Options.t`'s `skip_lifting` field uses `Mutare.Lifting.skip_entry`).
  # Typespec autolinking bypasses `:skip_code_autolink_to`, so those are silenced by the
  # *referencing* module instead — keep this list tight.
  @typespec_refs_to_hidden ~w(Mutare.Calls Mutare.Options Mutare.Schema)

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
      aliases: aliases(),
      # PropCheck.App starts `PropCheck.CounterStrike`, which opens a single
      # on-disk DETS file (`_build/propcheck.ctex` by default) at *application
      # boot* — i.e. on every `mix test` invocation, whether or not a
      # `:property` test actually runs. Under `mix mutare --workers N` (N > 1),
      # several `mix test` OS processes boot concurrently against the *same*
      # sandboxed `_build`, and concurrent DETS opens/writes corrupt that file.
      # Once corrupted it stays corrupted on disk, so — with `--keep-sandbox`
      # — every subsequent run (any mutant, even a future invocation) fails
      # `PropCheck.CounterStrike.init/1` and the *entire* baseline suite reports
      # not-green, which mutare surfaces only as undifferentiated
      # `:harness_error` on every mutant. Found dogfooding mutare on itself
      # (`--workers 4`); see NOTES.md "PropCheck counter-examples DETS
      # corruption under concurrent workers". Give each `mix test` process
      # (identified by its own BEAM's OS pid) a private counter-examples file
      # while under mutation (`MUTARE_ACTIVE_MUTANT` is set on the baseline,
      # the coverage probe, and every mutant run — see `test/test_helper.exs`);
      # normal local/CI runs keep the shared, cross-run-cached default file.
      # Placed under the sandbox's own `_build` (every sandboxed `mix test` has
      # its cwd set there — `Sandbox.Command.Invocation`), not the OS-wide tmp
      # dir, so an ephemeral (non-`--keep-sandbox`) sandbox's teardown
      # (`File.rm_rf(sandbox)`) removes it too instead of leaking one file per
      # mutant run into `/tmp` forever.
      propcheck: [
        counter_examples:
          if System.get_env("MUTARE_ACTIVE_MUTANT") do
            Path.join(File.cwd!(), "_build/propcheck-#{System.pid()}.ctex")
          end
      ]
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
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/mutare/changelog.html"
      },
      # Hex's default file set already includes LICENSE*, README*, mix.exs,
      # and lib/; list it explicitly so the bundled demo projects don't slip
      # into the package while keeping the licence and docs in.
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"]
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
      extras: ["README.md", "guides/extending.md", "CHANGELOG.md", "LICENSE"],
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
          Mutare.Run,
          Mutare.Runner,
          Mutare.Options,
          Mutare.Result,
          Mutare.Site
        ],
        "Writing mutators": [
          Mutare.Mutator,
          Mutare.Mutator.Structural,
          Mutare.Mutator.MacroHost,
          Mutare.Mutator.Mutation,
          Mutare.Mutator.Spec,
          Mutare.AST,
          Mutare.Test,
          Mutare.Test.RoutingExtension,
          Mutare.Calls,
          Mutare.Analyze
        ],
        "Writing extensions": [
          Mutare.Extension,
          Mutare.Extension.Spec,
          Mutare.CallRouting,
          Mutare.CallRouting.Registry,
          Mutare.CallRouting.Spec,
          Mutare.UseExpansion,
          Mutare.UseExpansion.Expansion,
          Mutare.UseExpansion.ContractError
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
