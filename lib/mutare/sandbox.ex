defmodule Mutare.Sandbox do
  @moduledoc """
  Materialise a schema as a runnable copy of the target project.

  We copy the project to a dedicated directory (excluding build output), write
  each metamutant over its original, and inject a tiny bootstrap into
  `test/test_helper.exs` that reads `MUTARE_ACTIVE_MUTANT` into `:persistent_term`
  before the suite starts. A second injection prefixes `config/config.exs` with
  the owner-death watcher (`Mutare.Sandbox.Command.Invocation.owner_watch_ast/0`),
  so every sandbox `mix` — including the one-time compile, which runs before any
  test bootstrap — halts itself if the Mutare process that spawned it dies,
  instead of surviving as an orphan. Everything injected is plain Erlang/Elixir
  with no dependency on Mutare, so the sandbox needs nothing added to its deps.
  Sandbox `mix.exs` files also wrap `project/0` to disable signature inference
  in the effective compiler options (`Mutare.Sandbox.CompilerOptions`), including
  every umbrella child. The target's own project files remain untouched.

  One copy serves every concurrent mutant run: they share this sandbox and its
  `_build`, and Mix's build lock serialises only their `--no-compile` boot check —
  a small, fixed fraction of a run (measured in `NOTES.md`,
  "Per-worker `MIX_BUILD_PATH` vs the shared sandbox build") — so there is no
  per-worker isolation to configure.

  Two materialisation modes, chosen by `:keep_sandbox`:

    * **kept (default, `keep_sandbox: true`)** — the sandbox (and its compiled `_build`)
      is *preserved* between runs and re-materialised in place: a file is
      rewritten only when its desired content differs (unchanged files keep their
      mtime, so mix's incremental compiler reuses `_build`), and files Mutare no
      longer owns are pruned. The mirror carries each source's permission mode and
      recreates its symlinks (never following them), matching what the fresh copy
      preserves. Without an explicit `:sandbox` it lives at a stable per-project
      temp dir; CI pins `:sandbox` at a cached directory instead. See `NOTES.md`
      for the cache pattern.
    * **fresh (`keep_sandbox: false`)** — a throwaway dir is wiped and re-copied every run, so
      the metamutant recompiles cold, and the runner removes it afterwards. Always correct, no
      caching — the reset for a kept sandbox that has gone bad.

  Materialising the workspace lives here; running `mix` against it (and the
  per-mutant timeout cap the bootstrap honours) lives in
  `Mutare.Sandbox.Command.Invocation`.
  """

  require Logger

  alias Mutare.{Options, Project, Schema}
  alias Mutare.Coverage.Recorder
  alias Mutare.Run.Context
  alias Mutare.Sandbox.{CompilerOptions, Lock, Ownership, Paths, Seed}
  alias Mutare.Sandbox.Command.Invocation

  # Sourced from `Mutare.Sandbox.Lock` (its single owner) so the excluded-paths list and the
  # ownership guard (`Mutare.Sandbox.Ownership`) share one lock filename.
  @lock_name Lock.name()
  @excluded ~w(_build .git .elixir_ls .lexical cover) ++ [@lock_name]

  # The permission bits of a `File.Stat` mode, masking off the file-type bits, so a
  # mirrored mode compares and chmods cleanly (`0o100755` → `0o755`).
  @permission_bits 0o7777

  # The build environment every sandbox `mix` runs under is owned by
  # `Mutare.Sandbox.Command.Invocation` (`Invocation.mix_env/0`), which sets it on
  # every invocation — so the dependencies' compiled artifacts we seed (see
  # `Mutare.Sandbox.Seed.dep_build/2`) live under `_build/<env>/lib`.

  # The bootstrap is three dependency-free snippets, each rendered the same way
  # from a quoted AST its owner defines: the mutant selector
  # (`Mutare.Selector.bootstrap_ast/0`), the per-mutant timeout watcher
  # (`Mutare.Sandbox.Command.Invocation.watcher_ast/0`), and the owner-death
  # watcher (`Invocation.owner_watch_ast/0`). Both watchers enforce their bound
  # *portably* — instead of the runner killing a hung OS process tree (which
  # needs platform-specific signals), the mutant process halts *itself*: after
  # the deadline for the timeout, on stdin EOF (the spawning Mutare process died)
  # for the owner watch. `System.halt/1` stops the VM immediately and
  # uncatchably, and the BEAM preempts a looping process so a watcher always gets
  # to run; if the suite finishes first they die with the VM. Each snippet stays
  # owned next to its own constants and is parsed at build time, not assembled
  # here as a string.
  @selector_bootstrap Macro.to_string(Mutare.Selector.bootstrap_ast())
  @timeout_watcher Macro.to_string(Invocation.watcher_ast())
  @owner_watcher Macro.to_string(Invocation.owner_watch_ast())

  @bootstrap """
  # ---- injected by Mutare: select the active mutant from the environment ----
  #{@selector_bootstrap}

  # ---- injected by Mutare: per-mutant timeout (self-halt; no external kill) --
  #{@timeout_watcher}

  # ---- injected by Mutare: halt when the spawning Mutare process dies --------
  #{@owner_watcher}
  # ---------------------------------------------------------------------------
  """

  # The owner-death watcher again, as a `config/config.exs` prefix: mix evaluates
  # config at boot, *before* the compilers run, so this one injection covers the
  # runs the test bootstrap can't — the one-time metamutant compile (the run most
  # likely to be killed mid-flight and orphaned) and every `mix test`'s boot
  # phase. Prepended ahead of the target's own config so it is armed before any
  # config code that might raise; it calls no `Config` macro, so position is
  # otherwise irrelevant. Inert without `Invocation.owner_watch_env/0` (only
  # `Invocation.mix/4` sets it), so a manual run in a kept sandbox is unaffected.
  #
  # The same "before the compilers run" property carries the compile's wall-clock
  # cap (`Invocation.compile_watcher_ast/0`) — the same self-halt watcher as the
  # per-mutant cap, armed by a dedicated env var (`Invocation.compile_timeout_env/0`)
  # that only the runner's compile invocation sets, so every other sandbox boot
  # evaluates it inert.
  @compile_watcher Macro.to_string(Invocation.compile_watcher_ast())
  @config_rel "config/config.exs"
  @config_bootstrap """
  # ---- injected by Mutare: halt when the spawning Mutare process dies --------
  #{@owner_watcher}
  # ---- injected by Mutare: wall-clock cap for the one metamutant compile -----
  #{@compile_watcher}
  # ---------------------------------------------------------------------------
  """

  # The coverage probe must start tracking before user `test_helper.exs` code,
  # because helpers often start the app or touch mutated code. `ExUnit.after_suite/1`
  # is only registerable after `ExUnit.start/0`, though, so coverage is injected
  # in two pieces around the user's helper.
  @coverage_helper Recorder.helper_source()
  @coverage_setup """
  # ---- injected by Mutare: coverage setup (inert unless probing) ------------
  #{Macro.to_string(Recorder.setup_ast())}
  # ---------------------------------------------------------------------------
  """
  @coverage_after_suite """
  # ---- injected by Mutare: coverage dump (inert unless probing) -------------
  #{Macro.to_string(Recorder.after_suite_ast())}
  # ---------------------------------------------------------------------------
  """

  # Stable relative paths for the two files Mutare generates (vs. copies). The
  # coverage helper's collision-avoiding `_N` suffix is a fresh-mode-only fallback;
  # `keep_sandbox` materialisation always reuses this base path.
  @helper_rel "test/test_helper.exs"
  @default_helper "ExUnit.start()\n"
  @coverage_helper_rel "lib/__mutare__/coverage_helper.ex"

  @doc """
  Prepare a sandbox for `schema` taken from `root`. Returns the sandbox path.

  `opts` may be a `Mutare.Run.Context`, a `Mutare.Options` struct, or a keyword
  list. `:sandbox` selects the target directory; without it Mutare uses a stable
  per-project temp directory (kept mode, the default) or a fresh one (`keep_sandbox:
  false`). The context's project scope controls which umbrella apps are
  materialized.

  The sandbox must be separate from the project tree: it may not be the project
  root, contain the project, or live inside it. This check is done here because it
  depends on `root`.

  Mutare will only use a target path that is absent, empty, or already marked as a
  Mutare-owned sandbox. Any other existing path is refused without modification.
  An owned directory is reused only for an explicit `:sandbox` path or when
  `:keep_sandbox` is enabled. If a generated fresh-path sandbox already exists,
  Mutare treats it as a stale leftover and refuses it.
  """
  @spec prepare(Path.t(), Schema.t(), Context.t() | Options.t() | keyword()) :: Path.t()
  def prepare(root, %Schema{} = schema, opts \\ []) do
    context = Context.new(opts)
    options = context.options
    project = context.project
    sandbox = options.sandbox || default_sandbox(root, options.keep_sandbox)

    Paths.validate!(root, sandbox)
    Ownership.claim!(sandbox, options.keep_sandbox, options.sandbox != nil)

    # Built once for both modes: the manifest carries the generated files, and `wrapped`
    # names the `mix.exs` files whose inference override actually landed — which only the
    # rewrite itself knows, and which `Seed.app_build/6` needs below. `declined` pairs each
    # other `mix.exs` with the rewrite's reason: its project compiles with inference on, which
    # can stretch the one compile from seconds to hours, so each is narrated before it starts.
    {overrides, wrapped, declined} = override_files(root, schema, project)
    narrate_declined(context, declined)

    if options.keep_sandbox do
      # Reuse the existing sandbox (and its `_build`): re-materialise it in place,
      # touching only what changed and pruning what's gone.
      sync(root, sandbox, overrides)
    else
      # Bulk-copy the project, then overlay every generated file from the **one**
      # `override_files/3` manifest `sync/3` also uses (metamutant source, coverage
      # helper, wrapped test helper) — so adding a generated file is a single edit, not
      # one per mode.
      copy_project(root, sandbox)
      write_overrides(sandbox, overrides)
    end

    # Avoid recompiling unchanged dependencies on the one `mix compile` by seeding
    # their already-built artifacts from the original project. Runs for both modes
    # but only fills in deps the sandbox doesn't already have, so a `keep_sandbox`
    # re-run's preserved `_build` is left untouched (it seeds only the first run).
    Seed.dep_build(root, sandbox)

    # When a run rewrites only a handful of files (`--line`/`--since`/`--only`, or any
    # `paths:` narrowing — and even a full run with sparse mutation sites), the rest are
    # byte-identical to the original, so their already-built beams are valid. Seed the
    # mutated app's own `_build` too, so the one `mix compile` recompiles only the
    # metamutant file(s) instead of the whole (possibly huge) app — the first-run
    # experience when someone aims Mutare at a single module. Best-effort and fail-safe by
    # construction: it can only ever fall back to today's cold compile. `--no-seed-app-build`
    # (`:seed_app_build` false) opts out entirely, forcing a cold compile.
    #
    # Its outcome (seeded + reused/recompiled counts, a fall back to a cold compile, or
    # skipped) rides the `:on_phase` hook as a `{:seed_app_build, summary}` detail event, so
    # `--verbose` can surface both the speed-up and an otherwise-silent fallback. Fired here
    # (during the runner's `:compiling` phase) since this is where the seed decision is made.
    seed_summary = Seed.app_build(root, sandbox, schema, options, project, wrapped)
    Context.hook(context, :on_phase).({:seed_app_build, seed_summary})

    sandbox
  end

  @doc false
  @spec acquire_lock(Path.t(), Context.t() | Options.t() | keyword()) :: Lock.t() | nil
  def acquire_lock(root, opts \\ []) do
    context = Context.new(opts)
    options = context.options

    if reusable_sandbox?(options) do
      sandbox = options.sandbox || default_sandbox(root, options.keep_sandbox)

      Paths.validate!(root, sandbox)
      Ownership.ensure_lockable!(sandbox)
      Lock.acquire(sandbox)
    end
  end

  @doc false
  @spec release_lock(Lock.t() | nil) :: :ok
  def release_lock(lock), do: Lock.release(lock)

  @doc """
  Re-render `schema`'s metamutants into an already-prepared `sandbox`, in place.

  This is the poison-recovery path. After a failed compile removes the implicated
  mutant ids and rebuilds the schema, the project copy, bootstrap, coverage
  helper, and seeded builds are still valid. Only the metamutant source files may
  have changed.

  The rewrite is byte-aware, so unchanged files keep their timestamps and Mix
  recompiles as little as possible. The same sandbox path is returned.
  """
  @spec rematerialize(Path.t(), Schema.t()) :: Path.t()
  def rematerialize(sandbox, %Schema{} = schema) do
    write_metamutants(sandbox, schema)
    sandbox
  end

  @doc "The bootstrap snippet prepended to the sandbox's test helper."
  @spec bootstrap() :: String.t()
  def bootstrap, do: @bootstrap

  # --- internals -----------------------------------------------------------

  # Fresh mode gets a unique throwaway dir, salted with this process's OS pid *and*
  # a per-run integer. `System.unique_integer/1` is unique only within *one* BEAM
  # instance, so across separate `mix mutare` runs (two concurrent invocations, or a
  # stale leftover in a shared `/tmp`) the counter restarts and repeats — two runs
  # could land on the same path, and `claim!`'s reset-when-owned would then let one
  # wipe the other's *live* sandbox mid-run (the "weird conflicts"). The OS pid
  # disambiguates concurrent processes and is not reused while this one is alive, so
  # the name is unique by construction. (Mirrors `Mutare.ChangesTest.fresh_tmp/1`.)
  #
  # Kept mode instead needs a *stable* path so the next run finds the same `_build`:
  # derive it deterministically from the project root (a per-project temp dir),
  # unless the caller pinned `:sandbox` explicitly.
  defp default_sandbox(_root, false) do
    Path.join(
      System.tmp_dir!(),
      "mutare_sandbox_#{System.pid()}_#{System.unique_integer([:positive])}"
    )
  end

  defp default_sandbox(root, true) do
    digest =
      :crypto.hash(:sha256, Path.expand(root))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    Path.join(System.tmp_dir!(), "mutare_sandbox_#{digest}")
  end

  defp reusable_sandbox?(%Options{sandbox: sandbox, keep_sandbox: keep_sandbox}),
    do: keep_sandbox or sandbox != nil

  defp copy_project(root, sandbox) do
    for entry <- File.ls!(root), entry not in @excluded do
      File.cp_r!(Path.join(root, entry), Path.join(sandbox, entry))
    end
  end

  # The byte-aware sandbox writer lets poison recovery (`rematerialize/2`) touch
  # only changed metamutants, preserving other mtimes for Mix's incremental compiler.
  # Selection can leave an entry identical to its original even on the first write.
  defp write_metamutants(sandbox, %Schema{metamutants: metamutants}) do
    for {rel, source} <- metamutants do
      put_sandbox_file_if_changed(sandbox, rel, source)
    end
  end

  # Overlay each generated file (the `override_files/3` manifest) onto the bulk-copied project
  # — the fresh-mode counterpart to `sync/3`'s in-place overlay, sharing the one manifest.
  # The byte-aware sandbox writer keeps unchanged entries at their copied mtime.
  defp write_overrides(sandbox, overrides) do
    for {rel, content} <- overrides, do: put_sandbox_file_if_changed(sandbox, rel, content)
    :ok
  end

  # The first name in a generated family — `zero`, then `suffixed.(1)`,
  # `suffixed.(2)`, … — that `taken?` rejects: the shared "pick a generated name
  # that doesn't collide with what's already there" primitive. The family is
  # infinite and the taken set finite, so `Enum.find/2` always terminates.
  defp first_free(zero, suffixed, taken?) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn
      0 -> zero
      n -> suffixed.(n)
    end)
    |> Enum.find(&(not taken?.(&1)))
  end

  # Minimal child `mix.exs`: only `build_path` matters — it shares the umbrella's
  # single `_build`, so the app compiles once with the rest and its ebin is on the
  # path. No config/deps, so nothing here depends on the target's config layout.
  defp support_mix_exs(app) do
    """
    defmodule #{Macro.camelize(app)}.MixProject do
      use Mix.Project

      def project do
        [app: :#{app}, version: "0.0.0", build_path: "../../_build", elixir: "~> 1.10", deps: []]
      end

      def application, do: []
    end
    """
  end

  defp support_app_rel(root), do: Path.join("apps", support_app_name(root))

  # The umbrella coverage helper lives in a generated child app under `apps/`, named
  # to step aside from any real app at that name (`Mutare.Project` discovers apps from
  # the root, where this app never exists, so it carries no copy of the family: a real
  # `apps/mutare_support` is just a real app, and the helper lands at
  # `mutare_support_1`). Probed against the **project root** as the single source of
  # truth for both modes: in kept mode the name must stay stable across runs (the
  # sandbox accumulates the previous run's app, so probing *it* would drift the name
  # and defeat the `_build` cache), and in fresh mode the sandbox is a copy of root, so
  # the two agree.
  defp support_app_name(root) do
    first_free(
      "mutare_support",
      &"mutare_support_#{&1}",
      &File.exists?(Path.join([root, "apps", &1]))
    )
  end

  # The test helpers whose suite the runner will drive — each gets the selector/timeout/coverage
  # bootstrap wrapped in by `helper_files/2`. A single project has one (`test/test_helper.exs`);
  # an umbrella runs each app's suite sequentially in one BEAM (cwd = the app dir), so each app
  # with a `test/` tree gets its own copy — and *every* app, not just the mutated ones, because a
  # mutant in one app can be killed by a test in another, and the selector must be live in
  # whichever app's process runs the line.
  defp helper_rels(root, %{umbrella?: true, apps: apps}) do
    for %{dir: dir} <- apps,
        app_dir = Path.join(root, dir),
        File.dir?(Path.join(app_dir, "test")),
        do: Path.join([dir, "test", "test_helper.exs"])
  end

  # A single app (no project, or a non-umbrella one) keeps the pre-umbrella
  # behavior: the root helper, created if absent.
  defp helper_rels(_root, _project), do: [@helper_rel]

  # Wrap the user's test helper with the selector/timeout bootstrap and the
  # coverage probe (split around `ExUnit.start/0`; see the constants above). Shared
  # by both the fresh and keep paths so the rendered helper can't drift.
  defp helper_contents(user_source) do
    @bootstrap <> "\n" <> @coverage_setup <> "\n" <> user_source <> "\n" <> @coverage_after_suite
  end

  # === keep-sandbox incremental materialisation ==============================

  # Re-materialise an owned sandbox in place. A managed file is rewritten only when
  # its desired content differs (an unchanged file keeps its mtime, so mix's
  # incremental compiler reuses `_build`); files Mutare no longer owns are pruned.
  # `@excluded` dirs (notably `_build`/`cover`) are never read, written, or pruned,
  # so the compiled artifacts survive between runs.
  #
  # The mirror carries the source's *shape*, not just its bytes: permission modes and
  # symlinks, which `copy_project/2`'s `File.cp_r!` preserves for free and a
  # content-only sync would silently flatten (a `0755` script arriving `0644`, a symlink
  # vanishing) — NOTES "`--keep-sandbox`: incremental materialisation for CI caching".
  defp sync(root, sandbox, overrides) do
    sources = source_entries(root)
    source_set = MapSet.new(sources, fn {rel, _kind} -> rel end)

    managed =
      MapSet.union(source_set, MapSet.new([Ownership.marker_name() | Map.keys(overrides)]))

    # 1. mirror every source: file contents byte-aware, symlinks as symlinks (never
    #    followed), empty directories as directories. Paths a generated override owns are
    #    skipped — step 2 materialises those as ordinary files.
    for {rel, kind} <- sources, not Map.has_key?(overrides, rel) do
      mirror_source(root, sandbox, rel, kind)
    end

    # 2. write every generated file (metamutant source, injected test helper, coverage
    #    helper, config). Deliberately *after* the mirror, so an override always wins
    #    over a copied symlink at its own path or at one of its parents, and lands as a
    #    real file inside the sandbox instead of being written through the link.
    for {rel, content} <- overrides, do: put_sandbox_file_if_changed(sandbox, rel, content)

    # 3. mirror permission bits, last: a suite may invoke a project script or native
    #    helper, which needs its executable bit. Applied to overridden paths too — the
    #    metamutant of an executable script keeps the script's mode, as it does on the
    #    fresh path, where `File.cp_r!` copies the mode and the overlay's `File.write!`
    #    preserves it.
    for {rel, {:regular, mode}} <- sources, do: mirror_mode_if_changed(sandbox, rel, mode)

    # 4. drop anything left in the sandbox that Mutare should no longer own.
    prune(sandbox, managed)
  end

  defp mirror_source(root, sandbox, rel, {:regular, _mode}) do
    put_sandbox_file_if_changed(sandbox, rel, File.read!(Path.join(root, rel)))
  end

  defp mirror_source(_root, sandbox, rel, {:symlink, target}) do
    put_sandbox_symlink_if_changed(sandbox, rel, target)
  end

  # An empty source directory: created (or cleared of whatever else sat at its path), and
  # kept by `prune/2` because it is managed, even though nothing under it is.
  defp mirror_source(_root, sandbox, rel, :directory) do
    ensure_sandbox_parent!(sandbox, rel)
    ensure_sandbox_dir!(Path.join(sandbox, rel))
  end

  # The files Mutare generates rather than copies, keyed by sandbox-relative path (the same
  # key space as `Schema.metamutants` and `source_entries/1`) — the **single manifest** both
  # materialisation modes use: `sync/3` overlays it onto an existing sandbox, the fresh path
  # (`prepare/3`) `write_overrides/2`-es it over a fresh copy. Adding a generated file is one
  # edit here, automatically reaching both modes.
  #
  # Returns `{overrides, wrapped, declined}`, where `wrapped` holds the relative paths of the
  # `mix.exs` files that came back with an inference hook actually attached, and `declined`
  # pairs every other one with the rewrite's reason. `Seed` realigns compile manifests against
  # `wrapped`, never against the list we tried: a file we failed to wrap compiles with
  # inference on, and telling its manifest otherwise both leaves the pathology in place and
  # invents a cache-key mismatch that cold-compiles the app.
  defp override_files(root, %Schema{metamutants: metamutants}, project) do
    overrides =
      metamutants
      |> Map.merge(coverage_helper_files(root, project))
      |> Map.merge(helper_files(root, project))
      |> Map.merge(config_files(root))
      |> Map.merge(project_files(root, project))

    # Wrap in place. Rebuilding the whole map would walk every metamutant entry to reach the
    # handful of `mix.exs` ones.
    overrides
    |> Map.keys()
    |> Enum.filter(&(Path.basename(&1) == "mix.exs"))
    |> Enum.reduce({overrides, MapSet.new(), []}, fn rel, {acc, wrapped, declined} ->
      case CompilerOptions.project_source(Map.fetch!(acc, rel)) do
        {:hooked, source} ->
          {Map.put(acc, rel, source), MapSet.put(wrapped, rel), declined}

        {:declined, source, reason} ->
          {Map.put(acc, rel, source), wrapped, [{rel, reason} | declined]}
      end
    end)
  end

  # Log (opt-in debug) and relay each declined wrap on `:on_phase`, as `Seed` does for its own
  # fallback, so `--verbose` can say why the one compile runs long. In path order, so the
  # narration is stable from run to run.
  defp narrate_declined(context, declined) do
    on_phase = Context.hook(context, :on_phase)

    for {file, reason} <- Enum.sort(declined) do
      Logger.debug("Mutare: #{file} keeps type-signature inference on — " <> reason)
      on_phase.({:inference_override_declined, %{file: file, reason: reason}})
    end

    :ok
  end

  # Root and real umbrella children, plus the generated support project's mix.exs
  # already present in coverage_helper_files/2. Derived from the original project
  # on every materialisation so retained sandboxes never stack wrappers. An unreadable
  # mix.exs is dropped — the third way a project dir ends up unwrapped, and why `Seed`
  # cannot infer the wrapped set from `Project.project_dirs/1`.
  defp project_files(root, project) do
    for dir <- Project.project_dirs(project),
        rel = Project.project_file(dir),
        {:ok, source} <- [File.read(Path.join(root, rel))],
        into: %{},
        do: {rel, source}
  end

  # The root config with the owner-death watcher prepended (see
  # `@config_bootstrap`). Mix loads the default `config_path` whenever the file
  # exists, so a target that ships none gets a generated one holding just the
  # watcher. Deliberately no attempt to resolve a custom `config_path:` — that
  # would mean divining it from `mix.exs` without evaluating target build code.
  # A project pointing `config_path` elsewhere simply never loads this file
  # (harmless dead weight): its one-time compile goes unguarded, while its
  # `mix test` runs still carry the watcher via the test bootstrap. The content
  # is derived from the *root's* config on every (re-)materialisation, so
  # kept-mode syncs are stable and never stack a second prefix.
  defp config_files(root) do
    case File.read(Path.join(root, @config_rel)) do
      {:ok, original} -> %{@config_rel => @config_bootstrap <> "\n" <> original}
      {:error, _} -> %{@config_rel => "import Config\n\n" <> @config_bootstrap}
    end
  end

  # The dependency-free coverage helper, compiled with the app so the metamutant's per-site
  # `hit/1` call resolves (the module uses an Erlang-style atom name to avoid colliding with a
  # target's own `MutareCov`). A single app's root `lib/` is compiled, so the helper goes there;
  # an umbrella root has no compiled `lib/`, so it becomes a generated child app under `apps/`
  # that `mix compile` builds with the rest (its ebin is on every app's code path — no per-app
  # dep edit needed).
  defp coverage_helper_files(root, %{umbrella?: true}) do
    app_rel = support_app_rel(root)
    app = Path.basename(app_rel)

    %{
      Path.join([app_rel, "mix.exs"]) => support_mix_exs(app),
      Path.join([app_rel, "lib", "mutare_cov.ex"]) => @coverage_helper <> "\n"
    }
  end

  defp coverage_helper_files(root, _project) do
    %{coverage_helper_rel(root) => @coverage_helper <> "\n"}
  end

  # The single-app coverage-helper rel-path, probed against the **project root** (like
  # `support_app_name/1`), so both modes agree and the chosen path stays stable across kept
  # runs. The `_N` suffix is reached only if the target itself ships
  # `lib/__mutare__/coverage_helper.ex` (essentially never — the `__mutare__` namespace is
  # reserved); when it does, that file is a mutated source in `metamutants`, so probing root
  # steps the helper aside and the `Map.merge` keys stay distinct. (Fresh's sandbox is a copy of
  # root, so probing root matches probing the sandbox; probing the *accumulating* sandbox in
  # kept mode would instead drift the name run-to-run.)
  defp coverage_helper_rel(root) do
    first_free(
      @coverage_helper_rel,
      &"lib/__mutare__/coverage_helper_#{&1}.ex",
      &File.exists?(Path.join(root, &1))
    )
  end

  defp helper_files(root, project) do
    Map.new(helper_rels(root, project), fn rel ->
      user_helper =
        case File.read(Path.join(root, rel)) do
          {:ok, source} -> source
          _ -> @default_helper
        end

      {rel, helper_contents(user_helper)}
    end)
  end

  # Generated sandbox files must be materialised inside the sandbox even when the
  # copied target contained a symlink at that path (or in one of its parent
  # components). File.write!/2 would follow those symlinks and mutate the linked
  # file outside the sandbox, so this helper first recreates the path as ordinary
  # directories plus a regular file.
  defp put_sandbox_file_if_changed(sandbox, rel, content) do
    path = Path.join(sandbox, rel)
    ensure_sandbox_parent!(sandbox, rel)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size == byte_size(content) ->
        unless File.read(path) == {:ok, content}, do: File.write!(path, content)

      {:ok, %File.Stat{type: :regular}} ->
        File.write!(path, content)

      {:ok, %File.Stat{type: type}} ->
        remove_existing_path!(path, type)
        File.write!(path, content)

      {:error, :enoent} ->
        File.write!(path, content)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox file", path: path
    end
  end

  # A source symlink is recreated as a symlink carrying the *same* raw target, exactly
  # as `File.cp_r!` does on the fresh path — the link is never followed, so a link
  # pointing outside the project is copied, not chased, and nothing is ever written
  # through it. Generated overrides are overlaid afterwards (see `sync/3`), so a path
  # Mutare owns replaces the link rather than dereferencing it.
  defp put_sandbox_symlink_if_changed(sandbox, rel, target) do
    path = Path.join(sandbox, rel)
    ensure_sandbox_parent!(sandbox, rel)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        unless File.read_link(path) == {:ok, target} do
          File.rm!(path)
          File.ln_s!(target, path)
        end

      {:ok, %File.Stat{type: type}} ->
        remove_existing_path!(path, type)
        File.ln_s!(target, path)

      {:error, :enoent} ->
        File.ln_s!(target, path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox file", path: path
    end
  end

  # Only ever chmods a regular file, and only when the bits actually differ: the sandbox
  # path may legitimately have become something else (a symlink Mutare no longer owns is
  # pruned, not chmodded), and a no-op chmod is not free — `File.chmod/2` is Erlang's
  # `write_file_info` with only the mode filled in, which resets the file's mtime to *now*.
  # That would hand mix a spuriously-changed file on every sync and undo the whole point of
  # the byte-aware mirror, so the mtime is put back after a real mode change.
  defp mirror_mode_if_changed(sandbox, rel, mode) do
    path = Path.join(sandbox, rel)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mode: current, mtime: mtime}}
      when Bitwise.band(current, @permission_bits) != mode ->
        File.chmod!(path, mode)
        File.touch!(path, mtime)

      _ ->
        :ok
    end
  end

  defp ensure_sandbox_parent!(sandbox, rel) do
    rel
    |> Path.dirname()
    |> Path.split()
    |> Enum.reject(&(&1 in [".", ""]))
    |> Enum.reduce(sandbox, fn part, parent ->
      path = Path.join(parent, part)
      ensure_sandbox_dir!(path)
      path
    end)
  end

  defp ensure_sandbox_dir!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        remove_existing_path!(path, type)
        File.mkdir!(path)

      {:error, :enoent} ->
        File.mkdir!(path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox directory", path: path
    end
  end

  defp remove_existing_path!(path, :directory), do: File.rm_rf!(path)
  defp remove_existing_path!(path, :symlink), do: File.rm!(path)
  defp remove_existing_path!(path, _type), do: File.rm!(path)

  # Every mirrorable entry under `root` (skipping `@excluded` at the top level, matching
  # `copy_project/2`) as `{rel, kind}`, with `rel` keyed exactly like `Schema.metamutants`
  # (`relative/2`) and `kind` recording what has to be recreated: `{:regular, mode}` (the
  # permission bits, file-type bits masked off), `{:symlink, target}` (the raw link
  # target), or `:directory` for a directory with nothing in it. A non-empty directory is
  # walked but is not itself an entry — it is implied by the files under it
  # (`ensure_sandbox_parent!`). An *empty* one has nothing to imply it, so it is an entry
  # of its own; without that a shallow git checkout under `deps/` loses its empty
  # `.git/refs/heads` and `.git/refs/tags`, git stops recognising the checkout, and Mix
  # reports every git dependency as a lock mismatch — a Phoenix app's `heroicons`/`daisyui`
  # (NOTES "The kept sandbox is the default"). A symlink is recorded, never descended, so
  # its subtree is mirrored only where it also lives under `root` in its own right. Anything
  # else (device, socket, unreadable) is skipped, as before.
  defp source_entries(root) do
    for entry <- File.ls!(root),
        entry not in @excluded,
        source <- walk(root, Path.join(root, entry)) do
      source
    end
  end

  defp walk(root, path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls!(path) do
          [] ->
            [{rel_path(root, path), :directory}]

          children ->
            for child <- children, source <- walk(root, Path.join(path, child)), do: source
        end

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        [{rel_path(root, path), {:regular, Bitwise.band(mode, @permission_bits)}}]

      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} -> [{rel_path(root, path), {:symlink, target}}]
          {:error, _} -> []
        end

      _ ->
        []
    end
  end

  defp rel_path(root, path), do: path |> Path.relative_to(root) |> to_string()

  # Delete sandbox files and symlinks not in `managed`, then any directory left empty —
  # unless the empty directory is itself managed (an empty source directory, mirrored on
  # purpose). Never descends `@excluded` dirs, so `_build`/`cover` and their artifacts
  # survive — nor a symlink (`lstat` types it as `:symlink`), so pruning removes the link
  # itself and never walks into whatever it points at.
  defp prune(sandbox, managed) do
    for entry <- File.ls!(sandbox), entry not in @excluded do
      prune_path(Path.join(sandbox, entry), entry, managed)
    end
  end

  defp prune_path(path, rel, managed) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        for child <- File.ls!(path),
            do: prune_path(Path.join(path, child), Path.join(rel, child), managed)

        if File.ls!(path) == [] and not MapSet.member?(managed, rel), do: File.rmdir!(path)

      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] ->
        unless MapSet.member?(managed, rel), do: File.rm!(path)

      _ ->
        :ok
    end
  end
end
