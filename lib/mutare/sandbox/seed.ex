defmodule Mutare.Sandbox.Seed do
  @moduledoc false
  # Seed a freshly-materialised sandbox's `_build` with already-compiled artifacts from the
  # original project, so the one `mix compile` rebuilds the minimum. Two independent seeds,
  # both best-effort and fail-safe (they can only ever fall back to a cold compile):
  #
  #   * `dep_build/2` — the dependencies' beams (`@excluded` keeps `_build` out of the copy,
  #     so without this every test-env dep recompiles cold each run).
  #   * `app_build/4` — the *mutated app's own* beams, so a narrow run (`--line`/`--since`/
  #     `--only`, a `paths:` narrowing, or a sparse-site full run) recompiles only the
  #     metamutant file(s), not the whole app.
  #
  # Extracted from `Mutare.Sandbox`; called from its `prepare/3` after materialisation.

  require Logger

  alias Mutare.{Options, Schema}
  alias Mutare.Sandbox.Command.Invocation

  # Seed the sandbox's `_build` with the dependencies' already-compiled artifacts
  # from the original project, so the one `mix compile` doesn't rebuild every
  # dependency from scratch.
  #
  # `@excluded` (in `Mutare.Sandbox`) keeps `_build` out of the copy, so a fresh sandbox
  # would otherwise recompile *all* test-env deps cold on every run — pure waste, since
  # their sources are copied byte-for-byte from a project the user already compiled (same
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
  @spec dep_build(Path.t(), Path.t()) :: :ok
  def dep_build(root, sandbox) do
    mix_env = Invocation.mix_env()
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
  # `dep_build/2` deliberately never seeds the app, because mix decides app-source
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
  @spec app_build(Path.t(), Path.t(), Schema.t(), Options.t()) :: :ok
  def app_build(_root, _sandbox, _schema, %Options{seed_app_build: false}), do: :ok

  # Gated on the actual *outcome* (`worth_seeding?/2`), not on which flag scoped the run:
  # `metamutants` already reflects every narrowing, so the gate can't miss one (a `--only`
  # / `paths:` narrowing has no `:only_*` field to check). Idempotent like the dep seed
  # (only fills an app the sandbox lacks), so a `keep_sandbox` re-run's preserved `_build`
  # is untouched and only the first run seeds.
  def app_build(root, sandbox, %Schema{metamutants: metamutants}, %Options{}) do
    mix_env = Invocation.mix_env()
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

      case do_seed(to_seed, meta_sources, expanded_root, expanded_sandbox) do
        # Only keep the seed if we *guaranteed* every metamutant will recompile.
        {:ok, forced} -> unless MapSet.subset?(meta_sources, forced), do: teardown(to_seed)
        {:error, message} -> tear_down_after(message, to_seed)
      end
    end

    :ok
  end

  # The seeding work, isolated so `app_build/4`'s happy path reads as a plain `case`. Copies
  # each seedable app into the sandbox `_build`, deletes the metamutant beams (so they
  # recompile) and relocates manifests, returning the set of source files whose beams were
  # forced to recompile — or `{:error, message}` if any file op raised/threw (→ cold compile).
  defp do_seed(to_seed, meta_sources, expanded_root, expanded_sandbox) do
    forced =
      Enum.reduce(to_seed, MapSet.new(), fn {src, dst}, found ->
        File.mkdir_p!(Path.dirname(dst))
        File.cp_r!(src, dst)
        deleted = delete_metamutant_beams(dst, meta_sources)
        relocate_manifests(dst, expanded_root, expanded_sandbox)
        MapSet.union(found, deleted)
      end)

    {:ok, forced}
  rescue
    e ->
      {:error,
       "Mutare: app-build seed failed, falling back to cold compile: " <> Exception.message(e)}
  catch
    kind, reason ->
      {:error,
       "Mutare: app-build seed aborted (#{kind} #{inspect(reason)}), falling back to cold compile"}
  end

  defp tear_down_after(message, to_seed) do
    Logger.debug(message)
    teardown(to_seed)
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
  # Structs are left *whole* (the `%_{}` clause): the manifest's own path fields are plain
  # maps/lists/tuples/binaries, and any struct here is a captured `compile_env` value (a
  # `Regex`, `Range`, `MapSet`, …) — data we must not rewrite, and which would crash the
  # generic map clause besides.
  defp rewrite_paths(term, root, sandbox) when is_binary(term) do
    cond do
      term == root -> sandbox
      String.contains?(term, root <> "/") -> String.replace(term, root <> "/", sandbox <> "/")
      true -> term
    end
  end

  # Cons-recurse rather than `Enum.map/2` so an improper list (a non-list tail) is walked
  # too, not crashed.
  defp rewrite_paths([head | tail], from, to),
    do: [rewrite_paths(head, from, to) | rewrite_paths(tail, from, to)]

  defp rewrite_paths([], _from, _to), do: []

  defp rewrite_paths(term, from, to) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&rewrite_paths(&1, from, to))
    |> List.to_tuple()
  end

  # A struct is captured `compile_env` data, not a manifest path field, so leave it whole.
  # Rewriting its internals risks corrupting a non-path binary, and a genuine path missed
  # inside one is fail-safe (it just provokes a recompile). This also sidesteps the
  # `Map.new/2` blowups the map clause hits on a struct, whose `Enumerable` is either
  # unimplemented (`Regex`, `Version`) or yields non-`{k, v}` elements (`Range`, `MapSet`).
  defp rewrite_paths(%_{} = term, _from, _to), do: term

  defp rewrite_paths(term, from, to) when is_map(term),
    do: Map.new(term, fn {k, v} -> {rewrite_paths(k, from, to), rewrite_paths(v, from, to)} end)

  defp rewrite_paths(term, _from, _to), do: term

  # Remove seeded app builds, returning the sandbox to its unseeded (cold-compile) state.
  defp teardown(to_seed), do: for({_src, dst} <- to_seed, do: File.rm_rf!(dst))
end
