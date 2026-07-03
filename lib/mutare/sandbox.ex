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

  Full-copy isolation is the simplest correct choice; swapping it for a shared
  build path is an open question to settle by measuring on a large umbrella.

  Two materialisation modes, chosen by `:keep_sandbox`:

    * **fresh (default)** — a throwaway dir is wiped (`reset!/1`) and re-copied
      every run, so the metamutant recompiles cold. Always correct, no caching.
    * **kept (`keep_sandbox: true`)** — the sandbox (and its compiled `_build`)
      is *preserved* between runs and re-materialised by `sync/4`: a file is
      rewritten only when its desired content differs (unchanged files keep their
      mtime, so mix's incremental compiler reuses `_build`), and files Mutare no
      longer owns are pruned. Intended for CI build caching; pair with a stable
      `:sandbox` path. See `NOTES.md` for the cache pattern.

  Materialising the workspace lives here; running `mix` against it (and the
  per-mutant timeout cap the bootstrap honours) lives in
  `Mutare.Sandbox.Command.Invocation`.
  """

  alias Mutare.{Options, Schema}
  alias Mutare.Coverage.Recorder
  alias Mutare.Run.Context
  alias Mutare.Sandbox.{CompilerOptions, Paths, Seed}
  alias Mutare.Sandbox.Command.Invocation

  @excluded ~w(_build .git .elixir_ls .lexical cover)

  # The build environment every sandbox `mix` runs under is owned by
  # `Mutare.Sandbox.Command.Invocation` (`Invocation.mix_env/0`), which sets it on
  # every invocation — so the dependencies' compiled artifacts we seed (see
  # `Mutare.Sandbox.Seed.dep_build/2`) live under `_build/<env>/lib`.

  # A sandbox is a throwaway copy we compile, mutate, and wipe. Before clearing a
  # directory we must be sure it is *ours* — not, say, a path `--sandbox` was
  # pointed at by mistake — so we never `rm_rf!` arbitrary user data. We take a
  # path only when it is one of:
  #
  #   1. absent — we create it;
  #   2. an empty directory — we adopt it; or
  #   3. a directory carrying our ownership marker — a sandbox from an earlier
  #      run, which we wipe and reuse (poison recovery rebuilds the same path).
  #
  # Anything else — a non-empty directory we never marked, a regular file, a
  # symlink — is refused untouched. The marker is a small dotfile whose first
  # line is a fixed signature; we verify its contents (not just its name) so a
  # coincidental file cannot hand us ownership of a directory we did not create.
  @marker_name ".mutare_sandbox"
  @marker_signature "mutare-sandbox-ownership-marker"
  @marker_body """
  #{@marker_signature}

  This directory is a Mutare sandbox: a compiled-and-mutated copy of a target
  project. Mutare overwrites and prunes it on every run — keep nothing here.
  """

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
  # The same "before the compilers run" property carries the other two snippets:
  #
  #   * type-signature inference off for the metamutant compile (a project-level
  #     `elixirc_options` setting with no CLI/env form — the config prefix is the
  #     one hook Mutare owns). Diagnostics-only, and pathological on
  #     metamutant-shaped code; rationale and measurements live on `CompilerOptions`.
  #   * the compile's wall-clock cap (`Invocation.compile_watcher_ast/0`) — the
  #     same self-halt watcher as the per-mutant cap, armed by a dedicated env var
  #     (`Invocation.compile_timeout_env/0`) that only the runner's compile
  #     invocation sets, so every other sandbox boot evaluates it inert.
  @infer_signatures_off Macro.to_string(CompilerOptions.infer_signatures_off_ast())
  @compile_watcher Macro.to_string(Invocation.compile_watcher_ast())
  @config_rel "config/config.exs"
  @config_bootstrap """
  # ---- injected by Mutare: halt when the spawning Mutare process dies --------
  #{@owner_watcher}
  # ---- injected by Mutare: wall-clock cap for the one metamutant compile -----
  #{@compile_watcher}
  # ---- injected by Mutare: skip type-signature inference (diagnostics-only) --
  #{@infer_signatures_off}
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
  list. `:sandbox` selects the target directory; without it Mutare uses a fresh
  temp directory. The context's project scope controls which umbrella apps are
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
    claim!(sandbox, options.keep_sandbox, options.sandbox != nil)

    if options.keep_sandbox do
      # Reuse the existing sandbox (and its `_build`): re-materialise it in place,
      # touching only what changed and pruning what's gone.
      sync(root, sandbox, schema, project)
    else
      # Bulk-copy the project, then overlay every generated file from the **one**
      # `override_files/3` manifest `sync/4` also uses (metamutant source, coverage
      # helper, wrapped test helper) — so adding a generated file is a single edit, not
      # one per mode.
      copy_project(root, sandbox)
      write_overrides(sandbox, override_files(root, schema, project))
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
    Seed.app_build(root, sandbox, schema, options)

    sandbox
  end

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

  # Take ownership of the sandbox path, then leave our marker. `lstat` (not
  # `stat`) so a symlink is seen as a symlink, never followed to a directory we
  # would then wipe. `pinned?` is whether the caller chose `:sandbox` explicitly
  # (vs. an auto-generated default) — it decides how an existing *owned* dir is
  # treated in fresh mode (see the cond).
  defp claim!(sandbox, keep?, pinned?) do
    case File.lstat(sandbox) do
      {:error, :enoent} ->
        File.mkdir_p!(sandbox)

      {:ok, %File.Stat{type: :directory}} ->
        handle_existing_dir!(sandbox, keep?, pinned?)

      {:ok, %File.Stat{type: type}} ->
        refuse!(sandbox, "is a #{type}, not a directory")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox", path: sandbox
    end

    put_if_changed(marker_path(sandbox), @marker_body)
  end

  # What to do with an existing *directory* at the sandbox path, by ownership and mode.
  defp handle_existing_dir!(sandbox, keep?, pinned?) do
    owned = owned?(sandbox)

    cond do
      # Keep mode reuses an owned dir *in place* — `sync` re-materialises it,
      # preserving its `_build`. Never wiped.
      keep? and owned ->
        :ok

      # Fresh mode at an explicitly pinned `:sandbox`: wiping a prior Mutare
      # sandbox at a fixed path is the documented, intended reuse.
      owned and pinned? ->
        reset!(sandbox)

      # Fresh mode at an auto-generated path: the pid-salted name cannot collide
      # with a *live* run, so an existing owned dir here is a stale leftover (or,
      # very rarely, an unexpected pid+counter collision). Refuse loudly rather
      # than silently wipe — clobbering a concurrently-active sandbox is exactly
      # the corruption the salting guards against.
      owned ->
        refuse_autogen!(sandbox)

      File.ls!(sandbox) == [] ->
        :ok

      true ->
        refuse!(sandbox, "is a non-empty directory without Mutare's ownership marker")
    end
  end

  # Ours iff the marker is a regular file whose contents start with our
  # signature — verified, so a coincidental dotfile can't grant ownership.
  defp owned?(sandbox) do
    path = marker_path(sandbox)

    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)) and
      match?({:ok, @marker_signature <> _}, File.read(path))
  end

  defp reset!(sandbox) do
    File.rm_rf!(sandbox)
    File.mkdir_p!(sandbox)
  end

  defp marker_path(sandbox), do: Path.join(sandbox, @marker_name)

  @spec refuse!(Path.t(), String.t()) :: no_return()
  defp refuse!(sandbox, reason) do
    raise ArgumentError,
          "refusing to use sandbox #{inspect(sandbox)}: it #{reason}. Mutare only writes " <>
            "to a path that is absent, an empty directory, or a previous Mutare sandbox; " <>
            "point it at a fresh or empty directory."
  end

  @spec refuse_autogen!(Path.t()) :: no_return()
  defp refuse_autogen!(sandbox) do
    raise ArgumentError,
          "refusing to use sandbox #{inspect(sandbox)}: it is an existing Mutare sandbox at an " <>
            "auto-generated path. That path is salted with this process's OS pid, so it cannot " <>
            "collide with a live run — this is a stale leftover from a halted run (or, rarely, " <>
            "an unexpected pid+counter collision). Mutare won't wipe it automatically; delete it " <>
            "and re-run, or pass an explicit --sandbox to reuse a fixed path."
  end

  defp copy_project(root, sandbox) do
    for entry <- File.ls!(root), entry not in @excluded do
      File.cp_r!(Path.join(root, entry), Path.join(sandbox, entry))
    end
  end

  # The sandbox writer is byte-aware (not a blind `File.write!`) so poison-recovery
  # rewrites
  # (`rematerialize/2`) touches only the metamutants whose rendered source changed,
  # leaving the rest at their original mtime for mix's incremental compiler. On the
  # first fresh write the copied original always differs from its metamutant, so
  # every mutated file is still written.
  defp write_metamutants(sandbox, %Schema{metamutants: metamutants}) do
    for {rel, source} <- metamutants do
      put_sandbox_file_if_changed(sandbox, rel, source)
    end
  end

  # Overlay each generated file (the `override_files/3` manifest) onto the bulk-copied project
  # — the fresh-mode counterpart to `sync/4`'s in-place overlay, sharing the one manifest.
  # The byte-aware sandbox writer keeps the rest at their copied mtime; the
  # metamutant always differs from the copied original on a fresh write, so
  # every mutated file is still written.
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
  # to avoid colliding with a real app (`Mutare.Project` reserves the `mutare_support`
  # prefix so it is never mutated). Probed against the **project root** as the single
  # source of truth for both modes: in kept mode the name must stay stable across runs
  # (the sandbox accumulates the previous run's app, so probing *it* would drift the
  # name and defeat the `_build` cache), and in fresh mode the sandbox is a copy of
  # root, so the two agree.
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
  defp sync(root, sandbox, %Schema{} = schema, project) do
    overrides = override_files(root, schema, project)
    sources = source_rel_paths(root)
    source_set = MapSet.new(sources)
    managed = MapSet.union(source_set, MapSet.new([@marker_name | Map.keys(overrides)]))

    # 1. mirror every source file, applying generated overrides (metamutant source
    #    and the injected test helper) in place of the original.
    for rel <- sources do
      content = Map.get_lazy(overrides, rel, fn -> File.read!(Path.join(root, rel)) end)
      put_sandbox_file_if_changed(sandbox, rel, content)
    end

    # 2. write generated files that have no backing source (the coverage helper,
    #    and the test helper when the target ships none).
    for {rel, content} <- overrides, not MapSet.member?(source_set, rel) do
      put_sandbox_file_if_changed(sandbox, rel, content)
    end

    # 3. drop anything left in the sandbox that Mutare should no longer own.
    prune(sandbox, managed)
  end

  # The files Mutare generates rather than copies, keyed by sandbox-relative path (the same
  # key space as `Schema.metamutants` and `source_rel_paths/1`) — the **single manifest** both
  # materialisation modes use: `sync/4` overlays it onto an existing sandbox, the fresh path
  # (`prepare/3`) `write_overrides/2`-es it over a fresh copy. Adding a generated file is one
  # edit here, automatically reaching both modes.
  defp override_files(root, %Schema{metamutants: metamutants}, project) do
    metamutants
    |> Map.merge(coverage_helper_files(root, project))
    |> Map.merge(helper_files(root, project))
    |> Map.merge(config_files(root))
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

  # Write only when the bytes actually change, so unchanged files keep their mtime.
  # A size check short-circuits the full read for the common unchanged-large-file
  # case.
  defp put_if_changed(path, content) do
    unless same_content?(path, content) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end
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

  defp same_content?(path, content) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size == byte_size(content) ->
        File.read(path) == {:ok, content}

      _ ->
        false
    end
  end

  # File rel-paths under `root` (skipping `@excluded` at the top level, matching
  # `copy_project/2`), keyed exactly like `Schema.metamutants` (`relative/2`).
  defp source_rel_paths(root) do
    for entry <- File.ls!(root),
        entry not in @excluded,
        rel <- walk(root, Path.join(root, entry)) do
      rel
    end
  end

  defp walk(root, path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        for child <- File.ls!(path), rel <- walk(root, Path.join(path, child)), do: rel

      {:ok, %File.Stat{type: :regular}} ->
        [path |> Path.relative_to(root) |> to_string()]

      _ ->
        []
    end
  end

  # Delete sandbox files not in `managed`, then any directory left empty. Never
  # descends `@excluded` dirs, so `_build`/`cover` and their artifacts survive.
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

        if File.ls!(path) == [], do: File.rmdir!(path)

      {:ok, %File.Stat{type: :regular}} ->
        unless MapSet.member?(managed, rel), do: File.rm!(path)

      _ ->
        :ok
    end
  end
end
