defmodule Mutare.Sandbox do
  @moduledoc """
  Materialise a schema as a runnable copy of the target project.

  We copy the project to a dedicated directory (excluding build output), write
  each metamutant over its original, and inject a tiny bootstrap into
  `test/test_helper.exs` that reads `MUTANT_UNDER_TEST` into `:persistent_term`
  before the suite starts. The bootstrap is plain Erlang/Elixir with no
  dependency on Mutare, so the sandbox needs nothing added to its deps.

  Full-copy isolation is the simplest correct choice; swapping it for a shared
  build path is an open question (see DESIGN.md) to settle by measuring on a
  large umbrella.

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
  per-mutant timeout cap the bootstrap honours) lives in `Mutare.Sandbox.Command`.
  """

  require Logger

  alias Mutare.{Options, Schema}
  alias Mutare.Coverage.Recorder
  alias Mutare.Sandbox.Command

  @excluded ~w(_build .git .elixir_ls .lexical cover)

  # The build environment every sandbox `mix` runs under is owned by
  # `Mutare.Sandbox.Command` (`Command.mix_env/0`), which sets it on every invocation —
  # so the dependencies' compiled artifacts we seed (see `seed_dep_build/2`) live under
  # `_build/<env>/lib`.

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

  # The bootstrap is two dependency-free snippets, each rendered the same way from
  # a quoted AST its owner defines: the mutant selector
  # (`Mutare.Selector.bootstrap_ast/0`) and the per-mutant timeout watcher
  # (`Mutare.Sandbox.Command.watcher_ast/0`). The watcher enforces the wall-clock
  # cap *portably* — instead of the runner killing a hung OS process tree (which
  # needs platform-specific signals), the mutant process halts *itself* after the
  # deadline. `System.halt/1` stops the VM immediately and uncatchably, and the
  # BEAM preempts a looping process so the watcher always gets to run; if the
  # suite finishes first it dies with the VM. Each snippet stays owned next to its
  # own constants and is parsed at build time, not assembled here as a string.
  @selector_bootstrap Macro.to_string(Mutare.Selector.bootstrap_ast())
  @timeout_watcher Macro.to_string(Command.watcher_ast())

  @bootstrap """
  # ---- injected by Mutare: select the active mutant from the environment ----
  #{@selector_bootstrap}

  # ---- injected by Mutare: per-mutant timeout (self-halt; no external kill) --
  #{@timeout_watcher}
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

  `opts` is a `Mutare.Options` (or a keyword list resolved into one); its
  `:sandbox` field is the target directory (default: a fresh temp dir).

  The sandbox must be disjoint from the project tree: it cannot be the project
  root, contain it, or be contained by it. `Options` validates the *shape* of the
  path; this disjointness check is enforced here because it is relative to `root`.

  To avoid deleting arbitrary data, the target path is only used when it is
  absent, an empty directory, or a directory carrying Mutare's ownership marker
  (a sandbox from an earlier run); anything else is refused untouched. An *owned*
  directory is reused only when its path was chosen explicitly (`:sandbox`) or in
  `--keep-sandbox` mode; an owned directory found at an auto-generated fresh path
  is treated as a stale leftover and refused, since the pid-salted name rules out
  a benign collision with a live run.
  """
  @spec prepare(Path.t(), Schema.t(), Options.t() | keyword()) :: Path.t()
  def prepare(root, %Schema{} = schema, opts \\ []) do
    options = Options.new(opts)
    sandbox = options.sandbox || default_sandbox(root, options.keep_sandbox)

    validate_paths!(root, sandbox)
    claim!(sandbox, options.keep_sandbox, options.sandbox != nil)

    if options.keep_sandbox do
      # Reuse the existing sandbox (and its `_build`): re-materialise it in place,
      # touching only what changed and pruning what's gone.
      sync(root, sandbox, schema, options)
    else
      # Bulk-copy the project, then overlay every generated file from the **one**
      # `override_files/3` manifest `sync/4` also uses (metamutant source, coverage
      # helper, wrapped test helper) — so adding a generated file is a single edit, not
      # one per mode.
      copy_project(root, sandbox)
      write_overrides(sandbox, override_files(root, schema, options))
    end

    # Avoid recompiling unchanged dependencies on the one `mix compile` by seeding
    # their already-built artifacts from the original project. Runs for both modes
    # but only fills in deps the sandbox doesn't already have, so a `keep_sandbox`
    # re-run's preserved `_build` is left untouched (it seeds only the first run).
    seed_dep_build(root, sandbox)

    # When a run rewrites only a handful of files (`--line`/`--since`/`--only`, or any
    # `paths:` narrowing — and even a full run with sparse mutation sites), the rest are
    # byte-identical to the original, so their already-built beams are valid. Seed the
    # mutated app's own `_build` too, so the one `mix compile` recompiles only the
    # metamutant file(s) instead of the whole (possibly huge) app — the first-run
    # experience when someone aims Mutare at a single module. Best-effort and fail-safe by
    # construction: it can only ever fall back to today's cold compile. `--no-seed-app-build`
    # (`:seed_app_build` false) opts out entirely, forcing a cold compile.
    seed_app_build(root, sandbox, schema, options)

    sandbox
  end

  @doc """
  Re-render `schema`'s metamutants into an already-prepared `sandbox`, in place.

  This is the **poison-recovery** path: after a failed compile drops the
  offending mutants and rebuilds the schema, only the metamutant *sources* differ
  — the copied project, injected bootstrap, coverage helper, and seeded deps are
  identical to the first `prepare/3`. So we rewrite just those sources (and only
  where their bytes changed, so mix recompiles the minimum), reusing the same
  sandbox path rather than materialising a fresh one each attempt. Keeping the
  path stable also keeps `prepare/3`'s ownership claim a once-per-run event.

  Returns `sandbox`, for symmetry with `prepare/3`.
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

  defp validate_paths!(root, sandbox) do
    root = resolve_path(root)
    expanded_sandbox = Path.expand(sandbox)

    # Two interpretations of where the sandbox *actually* lands, both checked against the project
    # root because materialisation `rm_rf!`s and rewrites that directory — if either resolves
    # inside the tree it could destroy source. They differ only when the final path component is
    # itself a symlink:
    #   1. `resolve_path(sandbox)` follows every symlink, the final component included — catches a
    #      sandbox that *is* a symlink into the tree (`/tmp/sb -> project/lib`).
    #   2. resolve only the *parent* chain, then re-join the literal basename — the spot where a
    #      not-yet-existing sandbox dir would be created (and wiped), catching a parent symlink
    #      that puts it inside the tree even when the leaf doesn't exist to resolve.
    # `Enum.uniq` collapses the common case where they agree. Don't fold this to a single path:
    # each interpretation guards a distinct symlink case the other misses.
    sandbox_paths =
      [
        resolve_path(expanded_sandbox),
        expanded_sandbox
        |> Path.dirname()
        |> resolve_path()
        |> Path.join(Path.basename(expanded_sandbox))
      ]
      |> Enum.uniq()

    case Enum.find_value(sandbox_paths, &overlap(&1, root)) do
      nil ->
        :ok

      relation ->
        raise ArgumentError,
              "unsafe sandbox path #{inspect(sandbox)}: it #{relation} the project root " <>
                "#{inspect(root)}; choose a directory outside the project tree"
    end
  end

  defp overlap(path, root) do
    cond do
      same_path?(path, root) -> "is"
      descendant?(path, root) -> "is inside"
      descendant?(root, path) -> "contains"
      true -> nil
    end
  end

  defp same_path?(left, right), do: path_components(left) == path_components(right)

  defp descendant?(path, parent) do
    path_parts = path_components(path)
    parent_parts = path_components(parent)

    length(path_parts) > length(parent_parts) and
      Enum.take(path_parts, length(parent_parts)) == parent_parts
  end

  defp path_components(path) do
    parts = Path.split(path)

    case :os.type() do
      {:win32, _} -> Enum.map(parts, &case_fold/1)
      {:unix, :darwin} -> Enum.map(parts, &case_fold/1)
      _ -> parts
    end
  end

  defp case_fold(part), do: part |> String.normalize(:nfc) |> String.downcase()

  # Resolve symlinks component-by-component so an existing symlinked parent
  # cannot make a lexically external sandbox land inside the project tree.
  defp resolve_path(path, links_left \\ 40) do
    path
    |> Path.expand()
    |> Path.split()
    |> then(fn [root | parts] -> resolve_parts(root, parts, links_left) end)
  end

  defp resolve_parts(path, [], _links_left), do: path

  defp resolve_parts(path, [part | rest], links_left) do
    candidate = Path.join(path, part)

    case File.read_link(candidate) do
      {:ok, _target} when links_left == 0 ->
        raise ArgumentError, "cannot validate path with more than 40 symbolic links"

      {:ok, target} ->
        target =
          case Path.type(target) do
            :absolute -> target
            _ -> Path.expand(target, path)
          end

        resolve_path(join_parts(target, rest), links_left - 1)

      {:error, :einval} ->
        resolve_parts(candidate, rest, links_left)

      {:error, :enoent} ->
        join_parts(candidate, rest)

      {:error, reason} ->
        raise ArgumentError,
              "cannot validate path #{inspect(candidate)}: #{:file.format_error(reason)}"
    end
  end

  defp join_parts(path, parts), do: Enum.reduce(parts, path, &Path.join(&2, &1))

  defp copy_project(root, sandbox) do
    for entry <- File.ls!(root), entry not in @excluded do
      File.cp_r!(Path.join(root, entry), Path.join(sandbox, entry))
    end
  end

  # Seed the sandbox's `_build` with the dependencies' already-compiled artifacts
  # from the original project, so the one `mix compile` doesn't rebuild every
  # dependency from scratch.
  #
  # `@excluded` keeps `_build` out of the copy, so a fresh sandbox would otherwise
  # recompile *all* test-env deps cold on every run — pure waste, since their
  # sources are copied byte-for-byte from a project the user already compiled (same
  # `mix.lock`). On a dependency-heavy app that cold rebuild dominates the whole
  # "compile once" step (often seconds to minutes). We copy each dep's build dir
  # (`ebin` + its `.mix` manifest), which is all mix needs to treat it as built: mix
  # gates dependency staleness on the lock + manifest, *not* per-source mtime, so
  # the copy's bumped mtimes don't provoke a rebuild (verified).
  #
  # Scoped deliberately to *dependencies*, never the mutated app(s): we copy only
  # the dirs named in the original's `deps/`, so we never seed an app's own beam.
  # An original app beam seeded over the metamutant could silently win and make
  # mutation testing a no-op (the hazard `keep_sandbox` guards), whereas leaving the
  # app dir absent forces mix to compile the freshly-written metamutant — what we
  # want.
  #
  # Idempotent and best-effort: a dep already present in the sandbox (a
  # `keep_sandbox` re-run's preserved `_build`) is skipped, and a dep with no
  # compiled artifacts (`only: :dev`, or an original that was never compiled in the
  # test env) is simply absent — falling back to a cold compile, never an error.
  defp seed_dep_build(root, sandbox) do
    mix_env = Command.mix_env()
    deps_lib = Path.join([root, "_build", mix_env, "lib"])

    for dep <- dep_names(root),
        src = Path.join(deps_lib, dep),
        File.dir?(src),
        dst = Path.join([sandbox, "_build", mix_env, "lib", dep]),
        not File.exists?(dst) do
      File.mkdir_p!(Path.dirname(dst))
      File.cp_r!(src, dst)
    end

    :ok
  end

  # Dependency names — the entries under the project's `deps/`, each a dep whose
  # compiled output lives at `_build/<env>/lib/<name>`. Umbrella in-project apps
  # live under `apps/`, never `deps/`, so this can never name a mutated app. A
  # dependency-free project (no `deps/`) yields none.
  defp dep_names(root) do
    case File.ls(Path.join(root, "deps")) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  # The largest fraction of the app's modules we'll recompile and still bother seeding.
  # Above it (most of the app is being mutated), the copy + beam scan can outweigh the
  # saving, so we fall back to a plain cold compile. Tunable.
  @seed_app_build_max_fraction 0.5

  # Seed the sandbox's `_build` with the *mutated app's own* already-compiled beams,
  # so a run that rewrites only a few files (`--line`/`--since`/`--only`, a `paths:`
  # narrowing, or a full run with sparse sites) recompiles just the metamutant file(s) —
  # not the whole application.
  #
  # `seed_dep_build/2` deliberately never seeds the app, because mix decides app-source
  # staleness from its compile manifest, which **embeds the absolute project path**:
  # transplanted to the sandbox (a different dir) the recorded paths don't match, so
  # mix treats every source as new and recompiles the lot. (Deps escape this: mix gates
  # a built dep as a *unit* on the lock, never re-running its per-source compile.) The
  # bigger hazard is the opposite one — seed an app's *original* beam and it can silently
  # win over the freshly-written metamutant, making mutation testing a no-op.
  #
  # We get both right:
  #
  #   * **Relocate the manifest** (`relocate_manifests/3`): rewrite the recorded project
  #     path to the sandbox path so mix accepts the seeded beams as the sandbox's own and
  #     reuses the unchanged files. The rewrite walks the decoded term replacing path
  #     binaries — it depends only on the *public* term format (`binary_to_term`) and
  #     "paths are stored as binaries", never on mix's private manifest layout, so it
  #     survives a manifest-version bump (worst case a spurious recompile, never a no-op).
  #   * **Delete the metamutant's beam** (`delete_metamutant_beams/2`): a *structural*
  #     guard against the no-op — a module with no beam *must* be recompiled, from the only
  #     source available (the metamutant), regardless of any mtime/checksum heuristic.
  #     Relocating the manifest restamps it to "now", so by mtime alone mix would consider
  #     the metamutant fresh and serve the stale beam (verified); the deletion is what
  #     forces the recompile.
  #
  # Fail-safe by construction: we keep the seed **only if every** metamutant's beam was
  # positively found and deleted (`MapSet.subset?`); on any shortfall — a beam whose
  # recorded source we couldn't match, or any error at all — we tear the seed back down
  # (`teardown/1`) and behave exactly as before (a cold compile). So a bug here can lose
  # the optimisation, never produce a wrong result.
  #
  # `--no-seed-app-build` opts out wholesale (force a cold compile — a debugging escape
  # hatch for the no-op surface, or a paranoid CI).
  defp seed_app_build(_root, _sandbox, _schema, %Options{seed_app_build: false}), do: :ok

  # Gated on the actual *outcome* (`worth_seeding?/2`), not on which flag scoped the run:
  # `metamutants` already reflects every narrowing, so the gate can't miss one (a `--only`
  # / `paths:` narrowing has no `:only_*` field to check). Idempotent like the dep seed
  # (only fills an app the sandbox lacks), so a `keep_sandbox` re-run's preserved `_build`
  # is untouched and only the first run seeds.
  defp seed_app_build(root, sandbox, %Schema{metamutants: metamutants}, %Options{}) do
    mix_env = Command.mix_env()
    src_lib = Path.join([root, "_build", mix_env, "lib"])
    dst_lib = Path.join([sandbox, "_build", mix_env, "lib"])

    to_seed =
      for app <- app_names(root, src_lib),
          src = Path.join(src_lib, app),
          File.dir?(src),
          dst = Path.join(dst_lib, app),
          not File.exists?(dst),
          do: {src, dst}

    if worth_seeding?(map_size(metamutants), to_seed) do
      expanded_root = Path.expand(root)
      expanded_sandbox = Path.expand(sandbox)
      meta_sources = MapSet.new(Map.keys(metamutants), &Path.join(expanded_root, &1))

      try do
        forced =
          Enum.reduce(to_seed, MapSet.new(), fn {src, dst}, found ->
            File.mkdir_p!(Path.dirname(dst))
            File.cp_r!(src, dst)
            deleted = delete_metamutant_beams(dst, meta_sources)
            relocate_manifests(dst, expanded_root, expanded_sandbox)
            MapSet.union(found, deleted)
          end)

        # Only keep the seed if we *guaranteed* every metamutant will recompile.
        unless MapSet.subset?(meta_sources, forced), do: teardown(to_seed)
      rescue
        e ->
          Logger.debug(
            "Mutare: app-build seed failed, falling back to cold compile: " <>
              Exception.message(e)
          )

          teardown(to_seed)
      catch
        kind, reason ->
          Logger.debug(
            "Mutare: app-build seed aborted (#{kind} #{inspect(reason)}), falling back to cold compile"
          )

          teardown(to_seed)
      end
    end

    :ok
  end

  # Worth seeding when the metamutant files are a small enough fraction of the app's
  # compiled modules — i.e. we'd reuse far more than we recompile. Reading the file set
  # (not a flag) means `--line`/`--since`/`--only`/a `paths:` narrowing, and a sparse-site
  # full run, are all handled uniformly, with no scoping mechanism to forget. Beam *names*
  # are listed (a cheap directory read, not a `:beam_lib` parse), so the check stays cheap
  # even on a large app.
  defp worth_seeding?(0, _to_seed), do: false
  defp worth_seeding?(_meta_count, []), do: false

  defp worth_seeding?(meta_count, to_seed) do
    total =
      to_seed
      |> Enum.map(fn {src, _dst} -> length(Path.wildcard(Path.join([src, "ebin", "*.beam"]))) end)
      |> Enum.sum()

    total > 0 and meta_count <= total * @seed_app_build_max_fraction
  end

  # The mutated app(s): every entry under the original's compiled `_build/<env>/lib`
  # that is *not* a dependency. Works for a single app and an umbrella alike (both put
  # in-project apps here; deps are listed under `deps/`). Absent build (never compiled)
  # yields none, so we simply skip the seed.
  defp app_names(root, src_lib) do
    case File.ls(src_lib) do
      {:ok, entries} -> entries -- dep_names(root)
      {:error, _} -> []
    end
  end

  # Delete every beam in `app_build`'s ebin whose recorded source is a metamutant file,
  # returning the set of sources whose beam we deleted. The source is read from the beam's
  # `compile_info` chunk via `:beam_lib` (a public, stable Erlang API), so the match is on
  # what mix actually compiled — not a guess from module names that nested modules,
  # `defimpl`s, or dynamic names could make incomplete.
  defp delete_metamutant_beams(app_build, meta_sources) do
    deleted =
      for beam <- Path.wildcard(Path.join([app_build, "ebin", "*.beam"])),
          source = beam_source(beam),
          source != nil and MapSet.member?(meta_sources, source) do
        File.rm!(beam)
        source
      end

    MapSet.new(deleted)
  end

  defp beam_source(beam) do
    case :beam_lib.chunks(to_charlist(beam), [:compile_info]) do
      {:ok, {_module, [compile_info: info]}} ->
        case Keyword.get(info, :source) do
          nil -> nil
          source -> Path.expand(to_string(source))
        end

      _ ->
        nil
    end
  end

  # Rewrite the compile manifests so their recorded project path points at the sandbox.
  # The manifest stores per-source paths *relative* to the project (already portable) plus
  # an *absolute* project-root reference — and that bare root is the staleness gate: left
  # pointing at the original dir, mix decides the build doesn't belong here and recompiles
  # everything. `File.write!` also restamps the manifest to "now" (>= the just-copied
  # sources), which is what makes the unchanged files non-stale and thus reused.
  defp relocate_manifests(app_build, root, sandbox) do
    for manifest <- Path.wildcard(Path.join([app_build, ".mix", "compile.{elixir,erlang}"])) do
      rewritten =
        manifest
        |> File.read!()
        |> :erlang.binary_to_term()
        |> rewrite_paths(root, sandbox)

      File.write!(manifest, :erlang.term_to_binary(rewritten))
    end
  end

  # Replace the project root with the sandbox in every path binary anywhere in `term`.
  # Structure-agnostic: it recurses through lists/tuples/maps and only ever touches
  # binaries, so it never has to understand the manifest's field layout. A binary is
  # rewritten only when it *is* the root or has it as a `/`-delimited prefix — so a sibling
  # project sharing a name prefix (`/p/app` vs `/p/app2`, a `path:` dep) is never touched.
  defp rewrite_paths(term, root, sandbox) when is_binary(term) do
    cond do
      term == root -> sandbox
      String.contains?(term, root <> "/") -> String.replace(term, root <> "/", sandbox <> "/")
      true -> term
    end
  end

  defp rewrite_paths(term, from, to) when is_list(term),
    do: Enum.map(term, &rewrite_paths(&1, from, to))

  defp rewrite_paths(term, from, to) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&rewrite_paths(&1, from, to))
    |> List.to_tuple()
  end

  defp rewrite_paths(term, from, to) when is_map(term),
    do: Map.new(term, fn {k, v} -> {rewrite_paths(k, from, to), rewrite_paths(v, from, to)} end)

  defp rewrite_paths(term, _from, _to), do: term

  # Remove seeded app builds, returning the sandbox to its unseeded (cold-compile) state.
  defp teardown(to_seed), do: for({_src, dst} <- to_seed, do: File.rm_rf!(dst))

  # `put_if_changed` (not a blind `File.write!`) so a poison-recovery rewrite
  # (`rematerialize/2`) touches only the metamutants whose rendered source changed,
  # leaving the rest at their original mtime for mix's incremental compiler. On the
  # first fresh write the copied original always differs from its metamutant, so
  # every mutated file is still written.
  defp write_metamutants(sandbox, %Schema{metamutants: metamutants}) do
    for {rel, source} <- metamutants do
      put_if_changed(Path.join(sandbox, rel), source)
    end
  end

  # Overlay each generated file (the `override_files/3` manifest) onto the bulk-copied project
  # — the fresh-mode counterpart to `sync/4`'s in-place overlay, sharing the one manifest.
  # `put_if_changed` keeps the rest at their copied mtime; the metamutant always differs from
  # the copied original on a fresh write, so every mutated file is still written.
  defp write_overrides(sandbox, overrides) do
    for {rel, content} <- overrides, do: put_if_changed(Path.join(sandbox, rel), content)
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
  defp sync(root, sandbox, %Schema{} = schema, %Options{} = options) do
    overrides = override_files(root, schema, options)
    sources = source_rel_paths(root)
    source_set = MapSet.new(sources)
    managed = MapSet.union(source_set, MapSet.new([@marker_name | Map.keys(overrides)]))

    # 1. mirror every source file, applying generated overrides (metamutant source
    #    and the injected test helper) in place of the original.
    for rel <- sources do
      content = Map.get_lazy(overrides, rel, fn -> File.read!(Path.join(root, rel)) end)
      put_if_changed(Path.join(sandbox, rel), content)
    end

    # 2. write generated files that have no backing source (the coverage helper,
    #    and the test helper when the target ships none).
    for {rel, content} <- overrides, not MapSet.member?(source_set, rel) do
      put_if_changed(Path.join(sandbox, rel), content)
    end

    # 3. drop anything left in the sandbox that Mutare should no longer own.
    prune(sandbox, managed)
  end

  # The files Mutare generates rather than copies, keyed by sandbox-relative path (the same
  # key space as `Schema.metamutants` and `source_rel_paths/1`) — the **single manifest** both
  # materialisation modes use: `sync/4` overlays it onto an existing sandbox, the fresh path
  # (`prepare/3`) `write_overrides/2`-es it over a fresh copy. Adding a generated file is one
  # edit here, automatically reaching both modes.
  defp override_files(root, %Schema{metamutants: metamutants}, %Options{} = options) do
    metamutants
    |> Map.merge(coverage_helper_files(root, options.project))
    |> Map.merge(helper_files(root, options.project))
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
