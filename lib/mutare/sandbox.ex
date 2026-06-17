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

  alias Mutare.{Options, Schema}
  alias Mutare.Coverage.Recorder
  alias Mutare.Sandbox.Command

  @excluded ~w(_build .git .elixir_ls .lexical cover)

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
  (a sandbox from an earlier run); anything else is refused untouched.
  """
  @spec prepare(Path.t(), Schema.t(), Options.t() | keyword()) :: Path.t()
  def prepare(root, %Schema{} = schema, opts \\ []) do
    options = Options.new(opts)
    sandbox = options.sandbox || default_sandbox(root, options.keep_sandbox)

    validate_paths!(root, sandbox)
    claim!(sandbox, options.keep_sandbox)

    if options.keep_sandbox do
      # Reuse the existing sandbox (and its `_build`): re-materialise it in place,
      # touching only what changed and pruning what's gone.
      sync(root, sandbox, schema, options)
    else
      copy_project(root, sandbox)
      write_metamutants(sandbox, schema)
      write_coverage_helper(sandbox, options)
      inject_bootstrap(sandbox, options)
    end

    sandbox
  end

  @doc "The bootstrap snippet prepended to the sandbox's test helper."
  @spec bootstrap() :: String.t()
  def bootstrap, do: @bootstrap

  # --- internals -----------------------------------------------------------

  # Fresh mode gets a unique throwaway dir. Kept mode needs a *stable* path so the
  # next run finds the same `_build`: derive it deterministically from the project
  # root (a per-project temp dir), unless the caller pinned `:sandbox` explicitly.
  defp default_sandbox(_root, false) do
    Path.join(System.tmp_dir!(), "mutare_sandbox_#{System.unique_integer([:positive])}")
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
  # would then wipe.
  defp claim!(sandbox, keep?) do
    case File.lstat(sandbox) do
      {:error, :enoent} ->
        File.mkdir_p!(sandbox)

      {:ok, %File.Stat{type: :directory}} ->
        cond do
          # Keep mode reuses an owned dir *in place* (sync re-materialises it);
          # fresh mode wipes it. Either way the path is ours to write.
          owned?(sandbox) -> unless keep?, do: reset!(sandbox)
          File.ls!(sandbox) == [] -> :ok
          true -> refuse!(sandbox, "is a non-empty directory without Mutare's ownership marker")
        end

      {:ok, %File.Stat{type: type}} ->
        refuse!(sandbox, "is a #{type}, not a directory")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox", path: sandbox
    end

    put_if_changed(marker_path(sandbox), @marker_body)
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

  defp validate_paths!(root, sandbox) do
    root = resolve_path(root)
    expanded_sandbox = Path.expand(sandbox)

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

  defp write_metamutants(sandbox, %Schema{metamutants: metamutants}) do
    for {rel, source} <- metamutants do
      path = Path.join(sandbox, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end
  end

  # The dependency-free coverage helper is compiled with the app, so the
  # metamutant's per-site `hit/1` call resolves. The helper module uses an
  # Erlang-style atom name to avoid Elixir module collisions (e.g. a target's own
  # `MutareCov`).
  #
  # A single app's root `lib/` is compiled, so the helper goes there under a
  # generated path chosen not to overwrite copied source. An umbrella root has no
  # compiled `lib/`, so the helper instead becomes a generated child app under
  # `apps/` — which `mix compile` builds with the rest and whose ebin the umbrella
  # puts on every app's code path (verified: no per-app dep edit needed).
  defp write_coverage_helper(sandbox, %Options{project: %{umbrella?: true}}) do
    dir = support_app_dir(sandbox)
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "mix.exs"), support_mix_exs(Path.basename(dir)))
    File.write!(Path.join(dir, "lib/mutare_cov.ex"), @coverage_helper <> "\n")
  end

  defp write_coverage_helper(sandbox, _options) do
    path = coverage_helper_path(sandbox)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @coverage_helper <> "\n")
  end

  defp coverage_helper_path(sandbox) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn
      0 -> @coverage_helper_rel
      n -> "lib/__mutare__/coverage_helper_#{n}.ex"
    end)
    |> Stream.map(&Path.join(sandbox, &1))
    |> Enum.find(&(not File.exists?(&1)))
  end

  # A generated child app under `apps/`, named to avoid colliding with a real app.
  # `Mutare.Project` reserves the `mutare_support` prefix so it is never mutated.
  defp support_app_dir(sandbox) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn
      0 -> "mutare_support"
      n -> "mutare_support_#{n}"
    end)
    |> Stream.map(&Path.join([sandbox, "apps", &1]))
    |> Enum.find(&(not File.exists?(&1)))
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

  defp support_app_name(root) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn
      0 -> "mutare_support"
      n -> "mutare_support_#{n}"
    end)
    |> Enum.find(&(not File.exists?(Path.join([root, "apps", &1]))))
  end

  # Inject the bootstrap into every test helper whose suite the runner will drive.
  # A single project has one (`test/test_helper.exs`); an umbrella runs each app's
  # suite sequentially in one BEAM (cwd = the app dir), so each app with a `test/`
  # tree gets its own copy — and *every* app, not just the mutated ones, because a
  # mutant in one app can be killed by a test in another, and the selector must be
  # live in whichever app's process runs the line.
  defp inject_bootstrap(sandbox, %Options{} = options) do
    for helper_rel <- helper_rels(sandbox, options.project) do
      inject_one(Path.join(sandbox, helper_rel))
    end
  end

  defp helper_rels(root, %{umbrella?: true, apps: apps}) do
    for %{dir: dir} <- apps,
        app_dir = Path.join(root, dir),
        File.dir?(Path.join(app_dir, "test")),
        do: Path.join([dir, "test", "test_helper.exs"])
  end

  # A single app (no project, or a non-umbrella one) keeps the pre-umbrella
  # behavior: the root helper, created if absent.
  defp helper_rels(_root, _project), do: [@helper_rel]

  defp inject_one(helper) do
    File.mkdir_p!(Path.dirname(helper))
    existing = if File.exists?(helper), do: File.read!(helper), else: @default_helper
    File.write!(helper, helper_contents(existing))
  end

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

  # The files Mutare generates rather than copies, keyed by sandbox-relative path
  # (the same key space as `Schema.metamutants` and `source_rel_paths/1`).
  defp override_files(root, %Schema{metamutants: metamutants}, %Options{} = options) do
    metamutants
    |> Map.merge(coverage_helper_files(root, options.project))
    |> Map.merge(helper_files(root, options.project))
  end

  defp coverage_helper_files(root, %{umbrella?: true}) do
    app_rel = support_app_rel(root)
    app = Path.basename(app_rel)

    %{
      Path.join([app_rel, "mix.exs"]) => support_mix_exs(app),
      Path.join([app_rel, "lib", "mutare_cov.ex"]) => @coverage_helper <> "\n"
    }
  end

  defp coverage_helper_files(_root, _project) do
    %{@coverage_helper_rel => @coverage_helper <> "\n"}
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
