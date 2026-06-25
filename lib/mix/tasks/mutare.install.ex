if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Mutare.Install do
    @shortdoc "Install and configure Mutare, wiring up framework mutator plugins"
    @moduledoc """
    Install Mutare and auto-configure its framework plugins.

        mix igniter.install mutare

    Adds `:mutare` to your `:dev`/`:test` dependencies (`runtime: false`), then looks
    at what your project already depends on and wires up the matching companion
    mutator packages — so a Phoenix/Ecto app gets framework-aware mutants without any
    manual configuration:

    | Detected dependency               | Plugin added                | Families enabled                  |
    | --------------------------------- | --------------------------- | --------------------------------- |
    | `:phoenix`                        | `mutare_phoenix`            | `Mutare.Phoenix.all/0`            |
    | `:phoenix_live_view`              | `mutare_phoenix_live_view`  | `Mutare.Phoenix.LiveView.all/0`   |
    | `:ecto` / `:ecto_sql`             | `mutare_ecto`               | `{Mutare.Ecto, repo: YourRepo}`   |

    Each detected plugin is added as a `:dev`/`:test` dependency and spliced into the
    `:mutators` list of a generated `.mutare.exs`, alongside the `:builtins` group
    token (which keeps Mutare's own families on). Nothing detected? You still get a
    starter `.mutare.exs` and a ready-to-run `mix mutare`.

    If you already have a `.mutare.exs`, it is left untouched and the recommended
    `:mutators` line is printed as a notice for you to merge in by hand.

    ## Options

      * `--repo MyApp.Repo` — the Ecto repo to configure `mutare_ecto` with. When
        omitted the repo is detected from your project (you are prompted if there is
        more than one); if none is found a `YourApp.Repo` placeholder is written and a
        warning tells you to edit it.
    """
    use Igniter.Mix.Task

    @example "mix igniter.install mutare"

    # Published plugin versions. Bump alongside the plugins' releases.
    @plugin_version "~> 0.1"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :mutare,
        example: @example,
        # How `mix igniter.install mutare` should add Mutare itself: a mutation-testing
        # tool belongs in dev/test only and runs as a Mix task, never at app runtime.
        only: [:dev, :test],
        dep_opts: [runtime: false],
        schema: [repo: :string]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      detected = %{
        phoenix: Igniter.Project.Deps.has_dep?(igniter, :phoenix),
        live_view: Igniter.Project.Deps.has_dep?(igniter, :phoenix_live_view),
        # A DB-backed app declares one of these in mix.exs (and pulls `:ecto` in
        # transitively); `has_dep?` only sees *declared* deps, so check each candidate
        # signal rather than the resolved tree.
        ecto:
          Enum.any?(
            [:ecto_sql, :phoenix_ecto, :ecto],
            &Igniter.Project.Deps.has_dep?(igniter, &1)
          )
      }

      {igniter, repo} = resolve_repo(igniter, detected.ecto)

      igniter
      |> add_plugin_deps(detected)
      |> configure(detected, repo)
    end

    # --- dependencies --------------------------------------------------------

    defp add_plugin_deps(igniter, detected) do
      igniter
      |> maybe_add_dep(detected.phoenix, :mutare_phoenix)
      |> maybe_add_dep(detected.live_view, :mutare_phoenix_live_view)
      |> maybe_add_dep(detected.ecto, :mutare_ecto)
    end

    defp maybe_add_dep(igniter, false, _name), do: igniter

    defp maybe_add_dep(igniter, true, name) do
      # Guard on `has_dep?` ourselves rather than rely on `add_dep`'s `:on_exists`, so a
      # plugin the user already pinned (a different version/source) is never clobbered.
      if Igniter.Project.Deps.has_dep?(igniter, name) do
        igniter
      else
        Igniter.Project.Deps.add_dep(
          igniter,
          {name, @plugin_version, only: [:dev, :test], runtime: false}
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
      if any_plugin?(detected) do
        expr = mutators_expr(detected, repo)

        igniter
        |> write_or_notice_config(expr)
        |> warn_missing_repo(detected, repo)
      else
        Igniter.create_new_file(igniter, ".mutare.exs", no_plugin_config(), on_exists: :skip)
      end
    end

    # Create `.mutare.exs` when absent; otherwise leave the user's file alone and tell
    # them the exact `:mutators` value to merge in (surgically rewriting a free-form,
    # `Code.eval`-d config script is more likely to mangle than to help).
    defp write_or_notice_config(igniter, expr) do
      if Igniter.exists?(igniter, ".mutare.exs") do
        Igniter.add_notice(igniter, """
        You already have a .mutare.exs, so it was left untouched. Add the plugin
        families to its `:mutators` key (keep `:builtins` to run Mutare's own too):

            mutators: #{expr}
        """)
      else
        Igniter.create_new_file(igniter, ".mutare.exs", plugin_config(expr))
      end
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

    # Build the `:mutators` source as a string, mirroring the plugins' documented
    # composition: a base list literal (`:builtins`, plus the configured `Mutare.Ecto`
    # entry) `++` each Phoenix preset call. Examples:
    #
    #   phoenix             → [:builtins] ++ Mutare.Phoenix.all()
    #   phoenix + liveview  → [:builtins] ++ Mutare.Phoenix.all() ++ Mutare.Phoenix.LiveView.all()
    #   ecto                → [:builtins, {Mutare.Ecto, repo: MyApp.Repo}]
    #   all three           → [:builtins, {Mutare.Ecto, repo: MyApp.Repo}] ++
    #                            Mutare.Phoenix.all() ++ Mutare.Phoenix.LiveView.all()
    defp mutators_expr(detected, repo) do
      literals =
        [":builtins"] ++
          if(detected.ecto, do: ["{Mutare.Ecto, repo: #{repo_literal(repo)}}"], else: [])

      base = "[" <> Enum.join(literals, ", ") <> "]"

      calls =
        [
          {detected.phoenix, "Mutare.Phoenix.all()"},
          {detected.live_view, "Mutare.Phoenix.LiveView.all()"}
        ]
        |> Enum.filter(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      Enum.join([base | calls], " ++ ")
    end

    defp repo_literal(nil), do: "YourApp.Repo"
    defp repo_literal(repo), do: inspect(repo)

    defp any_plugin?(detected), do: detected.phoenix or detected.live_view or detected.ecto

    # --- generated file bodies -----------------------------------------------

    defp plugin_config(expr) do
      # Run the keyword list through the formatter so a long `++` chain wraps cleanly;
      # the explanatory comment sits above it (comments aren't part of this AST).
      list = "[mutators: #{expr}]" |> Code.format_string!() |> IO.iodata_to_binary()

      """
      # Mutare configuration — `mix help mutare` documents every option (all optional).
      #
      # Setting `:mutators` replaces Mutare's default set, so the `:builtins` token keeps
      # the built-in families on alongside the plugin families wired up below. Drop a
      # family you don't want, or silence individual sites with `# mutare:ignore[family]`.
      #{list}
      """
    end

    defp no_plugin_config do
      """
      # Mutare configuration — `mix help mutare` documents every option. Every key is
      # optional, so you can delete this file to fall back to the defaults.
      #
      # `:mutators` defaults to the full built-in set. Narrow it to specific families,
      # or extend it with your own — the `:builtins` token keeps the defaults on:
      #
      #   mutators: [:builtins, MyApp.Mutators.Custom]
      #
      # No Phoenix, LiveView, or Ecto was detected; add one and re-run
      # `mix igniter.install mutare` to wire up the matching mutare_* plugin.
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
