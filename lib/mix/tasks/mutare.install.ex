if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Mutare.Install do
    @shortdoc "Install and configure Mutare, wiring up framework integrations"
    @moduledoc """
    Install Mutare and auto-configure its framework integrations.

        mix igniter.install mutare

    Adds `:mutare` to your `:dev`/`:test` dependencies (`runtime: false`), then looks at what your project already depends on and wires up the matching companion packages — so a Plug/Phoenix/Ecto/Oban/Decimal/Swoosh/Gettext app gets framework-aware mutants without any manual configuration:

    | Detected dependency                               | Package added              | Wired into                                                             |
    | ------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------- |
    | `:plug` / `:bandit` / `:plug_cowboy` / `:phoenix` | `mutare_plug`              | `:mutators` — `Mutare.Plug.all/0`                                      |
    | `:phoenix`                                        | `mutare_phoenix`           | `:mutators` — `Mutare.Phoenix.all/0`; `:extensions` — `Mutare.Phoenix` |
    | `:phoenix_live_view`                              | `mutare_phoenix_live_view` | `:mutators` — `Mutare.Phoenix.LiveView.all/0`                          |
    | `:ecto_sql` / `:phoenix_ecto` / `:ecto`           | `mutare_ecto`              | `:mutators` — `{Mutare.Ecto, repo: YourRepo}`                          |
    | `:oban` / `:oban_pro`                             | `mutare_oban`              | `:mutators` — `Mutare.Oban.all/0`                                      |
    | `:decimal`                                        | `mutare_decimal`           | `:mutators` — `Mutare.Decimal.all/0`                                   |
    | `:swoosh` / `:phoenix_swoosh`                     | `mutare_swoosh`            | `:mutators` — `Mutare.Swoosh.all/0`                                    |
    | `:phoenix_swoosh`                                 | `mutare_phoenix_swoosh`    | `:mutators` — `Mutare.Phoenix.Swoosh.all/0`                            |
    | `:gettext`                                        | `mutare_gettext`           | `:extensions` — `Mutare.Gettext`                                       |


    Each detected package is added as a `:dev`/`:test` dependency and wired into a generated `.mutare.exs`: a mutator package extends the `:mutators` list (alongside the `:builtins` group token, which keeps Mutare's own families on), while a non-mutating extension like `mutare_gettext` — which only teaches Mutare a library's compile-time vocabulary so the built-in mutators land on it correctly — joins the `:extensions` list. `mutare_phoenix` does both: its families join `:mutators`, and its front module — a `Mutare.CallRouting` extension that keeps Phoenix's compile-time macros (the router DSL, `~H`) out of the mutation set — joins `:extensions`. Nothing detected? You still get a starter `.mutare.exs` and a ready-to-run `mix mutare`.

    If you already have a `.mutare.exs`, it is left untouched and the recommended `:mutators` / `:extensions` keys are printed as a notice for you to merge in by hand.

    ## Options

      * `--repo MyApp.Repo` — the Ecto repo to configure `mutare_ecto` with. When omitted the repo is detected from your project (you are prompted if there is more than one); if none is found a `YourApp.Repo` placeholder is written and a warning tells you to edit it.
    """
    use Igniter.Mix.Task

    @example "mix igniter.install mutare"

    # Companion packages release independently of Mutare, so the installer adds
    # them with an open requirement: `mix deps.get` then resolves whatever version
    # is current and compatible (each companion pins the Mutare versions it
    # supports in its own mix.exs). This keeps the two uncoupled — a Mutare release
    # never has to re-pin or re-release the companions in lockstep.
    @companion_requirement ">= 0.0.0"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :mutare,
        example: @example,
        # How `mix igniter.install mutare` should add Mutare itself: a mutation-testing
        # tool belongs in dev/test only and runs as a Mix task, never at app runtime.
        # `:test` isn't belt-and-suspenders — see NOTES "Why `:mutare` (and companion
        # mutator packages) need `only: [:dev, :test]`, not just `:dev`".
        only: [:dev, :test],
        dep_opts: [runtime: false],
        schema: [repo: :string]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      detected = %{
        # Plug contributes mutator families (`Mutare.Plug.all/0`) for the `Plug.Conn` calls a
        # plug, router, or controller action performs. `has_dep?` only sees *declared* deps:
        # a Phoenix app declares `:phoenix` and pulls `:plug` in transitively, and a Plug-only
        # app may declare just its server (`:bandit` / `:plug_cowboy`) — so any of those
        # signals wires up `mutare_plug`.
        plug:
          Enum.any?(
            [:plug, :bandit, :plug_cowboy, :phoenix],
            &Igniter.Project.Deps.has_dep?(igniter, &1)
          ),
        # Phoenix layers the controller surface on Plug; `mutare_phoenix` layers on
        # `mutare_plug` the same way (and arrives alongside it above). Its front module is
        # also a `Mutare.CallRouting` extension, so it joins `:extensions` (below) to keep
        # Phoenix's compile-time macros (router DSL, `~H`) from poisoning the build.
        phoenix: Igniter.Project.Deps.has_dep?(igniter, :phoenix),
        live_view: Igniter.Project.Deps.has_dep?(igniter, :phoenix_live_view),
        # A DB-backed app declares one of these in mix.exs (and pulls `:ecto` in
        # transitively); `has_dep?` only sees *declared* deps, so check each candidate
        # signal rather than the resolved tree.
        ecto:
          Enum.any?(
            [:ecto_sql, :phoenix_ecto, :ecto],
            &Igniter.Project.Deps.has_dep?(igniter, &1)
          ),
        # Gettext is wired up as an extension, not a mutator family: it joins `:extensions`
        # (below), not `:mutators`. A Gettext-using app (every default Phoenix app, plus
        # any library that calls it) declares `:gettext` directly, so a declared-dep
        # check is enough.
        gettext: Igniter.Project.Deps.has_dep?(igniter, :gettext),
        # Oban contributes mutator families (`Mutare.Oban.all/0`). `mutare_oban` gates on
        # both the OSS `Oban.Worker` and the Pro `Oban.Pro.Worker` behaviour; a Pro-only
        # app may declare just `:oban_pro`, so check either signal.
        oban: Enum.any?([:oban, :oban_pro], &Igniter.Project.Deps.has_dep?(igniter, &1)),
        # Decimal contributes mutator families (`Mutare.Decimal.all/0`) for Decimal
        # arithmetic/comparison calls. Unlike Ecto, decimal-using packages normally
        # declare `:decimal` directly, so a declared-dep check is the right signal.
        decimal: Igniter.Project.Deps.has_dep?(igniter, :decimal),
        # Swoosh contributes mutator families (`Mutare.Swoosh.all/0`) for email
        # construction/delivery calls. A `phoenix_swoosh` app builds its emails through
        # `Swoosh.Email` too, and `has_dep?` only sees *declared* deps — a project may
        # declare just `:phoenix_swoosh` and pull `:swoosh` in transitively — so either
        # signal wires up `mutare_swoosh`.
        swoosh:
          Enum.any?([:swoosh, :phoenix_swoosh], &Igniter.Project.Deps.has_dep?(igniter, &1)),
        # phoenix_swoosh layers template rendering on Swoosh; `mutare_phoenix_swoosh`
        # layers on `mutare_swoosh` the same way (and arrives alongside it above).
        phoenix_swoosh: Igniter.Project.Deps.has_dep?(igniter, :phoenix_swoosh)
      }

      {igniter, repo} = resolve_repo(igniter, detected.ecto)

      igniter
      |> add_companion_deps(detected)
      |> fetch_companion_deps()
      |> configure(detected, repo)
    end

    # --- dependencies --------------------------------------------------------

    # Igniter fetches the dependencies an installer *declares* up front (`Info.installs` /
    # `Info.adds_deps`) before running it, but the companions are chosen at run time from
    # the project's own deps, so they are added inside `igniter/1` — and Igniter does
    # nothing with a dep added there beyond writing it to `mix.exs` at the very end. Left
    # at that, `mix igniter.install mutare` wrote a `.mutare.exs` naming modules of packages
    # it had never fetched or locked (found by the v0.1.0 release smoke test). So apply the
    # `mix.exs` change and run `deps.get` here, before `.mutare.exs` is written; the
    # remaining changes carry on to Igniter's final apply. Under `Igniter.Test` fetching is
    # illegal (and pointless): the tests assert on the igniter's deps instead.
    defp fetch_companion_deps(igniter) do
      if igniter.assigns[:test_mode?] do
        igniter
      else
        Igniter.apply_and_fetch_dependencies(igniter,
          yes: igniter.args.options[:yes],
          error_on_abort?: true,
          operation: "fetching Mutare's companion packages"
        )
      end
    end

    defp add_companion_deps(igniter, detected) do
      igniter
      |> maybe_add_dep(detected.plug, :mutare_plug)
      |> maybe_add_dep(detected.phoenix, :mutare_phoenix)
      |> maybe_add_dep(detected.live_view, :mutare_phoenix_live_view)
      |> maybe_add_dep(detected.ecto, :mutare_ecto)
      |> maybe_add_dep(detected.oban, :mutare_oban)
      |> maybe_add_dep(detected.decimal, :mutare_decimal)
      |> maybe_add_dep(detected.swoosh, :mutare_swoosh)
      |> maybe_add_dep(detected.phoenix_swoosh, :mutare_phoenix_swoosh)
      |> maybe_add_dep(detected.gettext, :mutare_gettext)
    end

    defp maybe_add_dep(igniter, false, _name), do: igniter

    defp maybe_add_dep(igniter, true, name) do
      # Guard on `has_dep?` ourselves rather than rely on `add_dep`'s `:on_exists`, so a
      # A companion package the user already pinned (a different version/source) is never clobbered.
      #
      # Scoped `only: [:dev, :test]` below like Mutare itself, and for the same non-obvious
      # reason (NOTES "Why `:mutare` (and companion mutator packages) need `only: [:dev,
      # :test]`, not just `:dev`"): a companion is a mutator package too (it implements
      # `Mutare.Mutator`), and Mix compiles any `only: [:dev, :test]` dep on every ordinary
      # `mix test`, whether or not the app's own code references it — so `:mutare` must be
      # reachable in `:test` for *this* package to compile there, regardless of whether the
      # user ever writes a custom mutator themselves.
      if Igniter.Project.Deps.has_dep?(igniter, name) do
        igniter
      else
        Igniter.Project.Deps.add_dep(
          igniter,
          {name, @companion_requirement, only: [:dev, :test], runtime: false}
        )
      end
    end

    # --- ecto repo -----------------------------------------------------------

    # No Ecto → no repo to resolve. With Ecto, honour an explicit `--repo`, else ask
    # Igniter to find the project's repo (`select_repo/1` prompts if there are several,
    # returns the sole one unprompted, and `nil` if there are none).
    defp resolve_repo(igniter, false), do: {igniter, nil}

    defp resolve_repo(igniter, true) do
      case igniter.args.options[:repo] do
        nil -> Igniter.Libs.Ecto.select_repo(igniter)
        str -> {igniter, str |> String.split(".") |> Module.concat()}
      end
    end

    # --- .mutare.exs ---------------------------------------------------------

    defp configure(igniter, detected, repo) do
      case config_entries(detected, repo) do
        [] ->
          Igniter.create_new_file(igniter, ".mutare.exs", starter_config(), on_exists: :skip)

        entries ->
          igniter
          |> write_or_notice_config(entries)
          |> warn_missing_repo(detected, repo)
      end
    end

    # The `.mutare.exs` keyword entries to write, in canonical order: mutator families
    # (`:mutators`) first, then non-mutating extensions (`:extensions`). Each is a
    # `{key, source_string}` pair, so the generated file body and the
    # leave-it-untouched notice render from the one description.
    defp config_entries(detected, repo) do
      mutators =
        if mutator_package?(detected), do: [mutators: mutators_expr(detected, repo)], else: []

      extensions =
        if extension_package?(detected),
          do: [extensions: extensions_expr(detected)],
          else: []

      mutators ++ extensions
    end

    # Create `.mutare.exs` when absent; otherwise leave the user's file alone and tell
    # them the exact keys to merge in (surgically rewriting a free-form, `Code.eval`-d
    # config script is more likely to mangle than to help).
    defp write_or_notice_config(igniter, entries) do
      if Igniter.exists?(igniter, ".mutare.exs") do
        Igniter.add_notice(igniter, """
        You already have a .mutare.exs, so it was left untouched. Merge these keys
        into it (keep `:builtins` in `:mutators` to run Mutare's own families too):

        #{entries_notice(entries)}
        """)
      else
        Igniter.create_new_file(igniter, ".mutare.exs", generated_config(entries))
      end
    end

    defp entries_notice(entries) do
      Enum.map_join(entries, "\n", fn {key, expr} -> "    #{key}: #{expr}" end)
    end

    defp warn_missing_repo(igniter, %{ecto: true}, nil) do
      Igniter.add_warning(igniter, """
      Could not find an Ecto repo, so mutare_ecto was configured with a placeholder
      `YourApp.Repo`. Edit .mutare.exs and set `repo:` to your repo module, or re-run
      with `mix igniter.install mutare --repo MyApp.Repo`.
      """)
    end

    defp warn_missing_repo(igniter, _detected, _repo), do: igniter

    # --- mutators expression -------------------------------------------------

    # Build the `:mutators` source as a string, mirroring the extensions' documented
    # composition: a base list literal (`:builtins`, plus the configured `Mutare.Ecto`
    # entry) `++` each companion preset call. Examples:
    #
    #   plug                → [:builtins] ++ Mutare.Plug.all()
    #   phoenix             → [:builtins] ++ Mutare.Plug.all() ++ Mutare.Phoenix.all()
    #   phoenix + liveview  → [:builtins] ++ Mutare.Plug.all() ++ Mutare.Phoenix.all() ++
    #                           Mutare.Phoenix.LiveView.all()
    #   ecto                → [:builtins, {Mutare.Ecto, repo: MyApp.Repo}]
    #   oban                → [:builtins] ++ Mutare.Oban.all()
    #   decimal             → [:builtins] ++ Mutare.Decimal.all()
    #   ecto + oban         → [:builtins, {Mutare.Ecto, repo: MyApp.Repo}] ++ Mutare.Oban.all()
    defp mutators_expr(detected, repo) do
      literals =
        [":builtins"] ++
          if(detected.ecto, do: ["{Mutare.Ecto, repo: #{repo_literal(repo)}}"], else: [])

      base = "[" <> Enum.join(literals, ", ") <> "]"

      calls =
        [
          {detected.plug, "Mutare.Plug.all()"},
          {detected.phoenix, "Mutare.Phoenix.all()"},
          {detected.live_view, "Mutare.Phoenix.LiveView.all()"},
          {detected.oban, "Mutare.Oban.all()"},
          {detected.decimal, "Mutare.Decimal.all()"},
          {detected.swoosh, "Mutare.Swoosh.all()"},
          {detected.phoenix_swoosh, "Mutare.Phoenix.Swoosh.all()"}
        ]
        |> Enum.filter(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      Enum.join([base | calls], " ++ ")
    end

    defp repo_literal(nil), do: "YourApp.Repo"
    defp repo_literal(repo), do: inspect(repo)

    # The `:extensions` source — non-mutating extensions, in registry order. Mirrors the
    # `calls` shape in `mutators_expr/2` so a future extension is a one-line addition.
    defp extensions_expr(detected) do
      modules =
        [{detected.phoenix, "Mutare.Phoenix"}, {detected.gettext, "Mutare.Gettext"}]
        |> Enum.filter(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      "[" <> Enum.join(modules, ", ") <> "]"
    end

    # Whether any detected dependency contributes a *mutator* family (and so a
    # `:mutators` key). Gettext is an extension, not a mutator, so it is excluded here.
    defp mutator_package?(detected),
      do:
        detected.plug or detected.phoenix or detected.live_view or detected.ecto or
          detected.oban or detected.decimal or detected.swoosh or detected.phoenix_swoosh

    # Whether any detected dependency contributes a non-mutating extension (and so an
    # `:extensions` key): Gettext, and Phoenix — a mutator package whose front module is
    # *also* a `Mutare.CallRouting` extension.
    defp extension_package?(detected), do: detected.phoenix or detected.gettext

    # --- generated file bodies -----------------------------------------------

    defp generated_config(entries) do
      # Run the keyword list through the formatter so a long `++` chain wraps cleanly;
      # the explanatory comment sits above it (comments aren't part of this AST).
      kw = Enum.map_join(entries, ", ", fn {key, expr} -> "#{key}: #{expr}" end)
      list = "[#{kw}]" |> Code.format_string!() |> IO.iodata_to_binary()

      """
      # Mutare configuration — `mix help mutare` documents every option (all optional).
      #
      # `:mutators` chooses the mutator families to run (defaults to every built-in). The
      # `:builtins` token keeps Mutare's own families on alongside any you add; drop a
      # family you don't want, or silence individual sites with `# mutare:ignore[family]`.
      #
      # `:extensions` lists non-mutating extensions that teach Mutare a library's
      # compile-time vocabulary (e.g. Gettext, or Phoenix's router DSL and `~H`) so the
      # built-in mutators land on it.
      #{list}
      """
    end

    defp starter_config do
      """
      # Mutare configuration — `mix help mutare` documents every option. Every key is
      # optional, so you can delete this file to fall back to the defaults.
      #
      # `:mutators` defaults to the full built-in set. Narrow it to specific families,
      # or extend it with your own — the `:builtins` token keeps the defaults on:
      #
      #   mutators: [:builtins, MyApp.Mutators.Custom]
      #
      # No Plug, Phoenix, LiveView, Ecto, Oban, Decimal, Swoosh, or Gettext was detected; add
      # one and re-run `mix igniter.install mutare` to wire up the matching mutare_* package.
      []
      """
    end
  end
else
  defmodule Mix.Tasks.Mutare.Install do
    @shortdoc "Install and configure Mutare (requires igniter)"
    @moduledoc @shortdoc
    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.raise("""
      The `mutare.install` task requires igniter, which is not available.

      Install the igniter archive and run the installer through it:

          mix archive.install hex igniter_new
          mix igniter.install mutare

      Or add Mutare to your deps by hand (in `:dev`/`:test`):

          {:mutare, "~> 0.1", only: [:dev, :test], runtime: false}
      """)
    end
  end
end
