defmodule Mutare.Project do
  @moduledoc """
  Resolve the *shape* of the target into a copy-root and a mutate-scope.

  Mutare copies one tree into the sandbox and mutates a set of source files in it.
  For a plain Mix project those are the same directory. For an **umbrella** they
  differ: the whole umbrella is copied (so `in_umbrella` sibling deps and the
  shared `deps/`/`config/` keep resolving), while only a chosen subset of `apps/*`
  gets metamutants.

  `resolve/2` turns the user-supplied target path plus the `--app`/`--workspace`
  flags into:

    * `copy_root` — the directory materialised into the sandbox (the umbrella
      root, or the project root for a single app). This is the `root` the rest of
      the pipeline (`Mutare.Schema`, `Mutare.Sandbox`, `Mutare.Runner`) treats as
      authoritative for every path operation; the struct duplicates it only so the
      entry points know what to pass.
    * `mutate_scope` — the apps whose sources are mutated, as `%{app, dir}` entries
      with `dir` relative to `copy_root` (`"apps/foo"`, or `"."` for a single app).
    * `apps` — every app whose suite runs (all umbrella apps), which the per-app
      bootstrap injection and the dependency-graph scoping need.

  Detection is **static** — Mutare runs outside the target's Mix, so the layout is
  read from the filesystem (an `apps/` dir plus an `apps_path:` in the root
  `mix.exs`) rather than from `Mix.Project`.
  """

  @type app :: %{app: atom() | nil, dir: String.t()}
  @type t :: %__MODULE__{
          copy_root: Path.t(),
          umbrella?: boolean(),
          mutate_scope: [app()],
          apps: [app()]
        }

  defstruct copy_root: ".", umbrella?: false, mutate_scope: [], apps: []

  # The generated coverage-support app (see `Mutare.Sandbox`) lives under `apps/`
  # in an umbrella but is never itself a mutation target.
  @reserved_prefix "mutare_support"

  @doc """
  Resolve `target` (+ scope flags) into a `t:t/0`.

  `opts`:
    * `:apps` — app-name strings to mutate (from `--app`); `nil`/`[]` means "all".
    * `:workspace` — `true` mutates every app (from `--workspace`).

  A single (non-umbrella) project resolves to `copy_root: target` with a lone
  `%{app: nil, dir: "."}` scope, so the existing single-app pipeline is unchanged.
  """
  @spec resolve(Path.t(), keyword()) :: t()
  def resolve(target, opts \\ []) do
    expanded = Path.expand(target)

    cond do
      umbrella_root?(expanded) -> from_umbrella_root(target, expanded, opts)
      umbrella_app?(expanded) -> from_app(expanded)
      true -> single_app(target)
    end
  end

  @doc "Is `dir` (an absolute path) the root of an umbrella project?"
  @spec umbrella_root?(Path.t()) :: boolean()
  def umbrella_root?(dir) do
    File.dir?(Path.join(dir, "apps")) and declares_apps_path?(Path.join(dir, "mix.exs"))
  end

  @doc """
  Per mutate-scope app, the root-relative `test/` dirs a broad (whole-suite) run
  may be narrowed to: the app itself plus every app that (transitively) depends on
  it. A mutant in app A can only be killed by a test that executes A's code, and a
  sibling executes A's code only through a declared dependency — so this set is a
  safe superset of A's possible killers; narrowing below it would risk a false
  survivor, so we never do.

  `forward` is the **declared** inter-app graph, `%{app => [apps it depends on]}`,
  as `Mutare.Runner.AppGraph.read/2` reads it from Mix (nodes and deps outside the
  umbrella are ignored). Declared, not runtime: a `runtime: false` sibling dep is
  absent from the compiled `.app`'s `applications` yet fully callable from the
  dependent's tests. Only dirs that actually exist under `sandbox` are returned.
  Returns `%{}` (⇒ no narrowing, run the whole umbrella) for a single app, or when
  `forward` lacks an umbrella app — a missing node would hide that app's
  dependents, so degrade safe rather than narrow on doubt.
  """
  @spec app_test_scopes(t(), Path.t(), %{atom() => [atom()]}) :: %{atom() => [String.t()]}
  def app_test_scopes(project, sandbox, forward)

  def app_test_scopes(
        %__MODULE__{umbrella?: true, apps: apps, mutate_scope: scope},
        sandbox,
        forward
      ) do
    names = MapSet.new(apps, & &1.app)
    dir_of = Map.new(apps, fn %{app: app, dir: dir} -> {app, dir} end)

    if Enum.all?(names, &Map.has_key?(forward, &1)) do
      reverse = invert(forward, names)

      Map.new(scope, fn %{app: app} ->
        dirs =
          reverse
          |> closure(app)
          |> Enum.map(&Path.join(dir_of[&1], "test"))
          |> Enum.filter(&File.dir?(Path.join(sandbox, &1)))
          |> Enum.sort()

        {app, dirs}
      end)
    else
      %{}
    end
  end

  def app_test_scopes(_project, _sandbox, _forward), do: %{}

  # --- internals -----------------------------------------------------------

  defp single_app(target) do
    only = [%{app: nil, dir: "."}]
    %__MODULE__{copy_root: target, umbrella?: false, mutate_scope: only, apps: only}
  end

  defp from_umbrella_root(target, expanded, opts) do
    all = discover_apps(expanded)

    %__MODULE__{
      copy_root: target,
      umbrella?: true,
      mutate_scope: select_scope(all, opts),
      apps: all
    }
  end

  # The target is an app inside an umbrella: copy the *umbrella* root, mutate only
  # this app. The umbrella root is two levels up (`<umbrella>/apps/<app>`); use its
  # absolute path as copy-root so the pipeline resolves siblings regardless of cwd.
  defp from_app(expanded) do
    umbrella_root = expanded |> Path.dirname() |> Path.dirname()
    all = discover_apps(umbrella_root)
    name = Path.basename(expanded)
    this = Enum.find(all, &(app_name(&1) == name)) || app_entry(name)

    %__MODULE__{
      copy_root: umbrella_root,
      umbrella?: true,
      mutate_scope: [this],
      apps: all
    }
  end

  defp discover_apps(umbrella_root) do
    apps_dir = Path.join(umbrella_root, "apps")

    case File.ls(apps_dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.filter(&app_dir?(Path.join(apps_dir, &1)))
        |> Enum.reject(&reserved?/1)
        |> Enum.map(&app_entry/1)

      _ ->
        []
    end
  end

  defp select_scope(all, opts) do
    cond do
      opts[:workspace] ->
        all

      opts[:apps] in [nil, []] ->
        all

      true ->
        wanted = MapSet.new(opts[:apps], &to_string/1)

        case Enum.filter(all, &MapSet.member?(wanted, app_name(&1))) do
          [] ->
            raise ArgumentError,
                  "no umbrella apps match #{inspect(opts[:apps])}; available: " <>
                    inspect(Enum.map(all, &app_name/1))

          scoped ->
            scoped
        end
    end
  end

  defp app_entry(name), do: %{app: String.to_atom(name), dir: Path.join("apps", name)}
  defp app_name(%{app: app}), do: to_string(app)
  defp app_dir?(path), do: File.regular?(Path.join(path, "mix.exs"))
  defp reserved?(name), do: String.starts_with?(name, @reserved_prefix)

  # Reverse the declared graph: `%{app => [apps that directly depend on it]}`, over
  # umbrella apps only (`forward` may carry nodes and edges outside `names`).
  defp invert(forward, names) do
    base = Map.new(names, &{&1, []})

    for {app, deps} <- forward,
        MapSet.member?(names, app),
        dep <- deps,
        MapSet.member?(names, dep),
        reduce: base do
      acc -> Map.update(acc, dep, [app], &[app | &1])
    end
  end

  # `app` plus every app transitively reachable through `reverse` (its dependents).
  defp closure(reverse, app) do
    grow(reverse, [app], MapSet.new())
  end

  defp grow(_reverse, [], seen), do: MapSet.to_list(seen)

  defp grow(reverse, [app | rest], seen) do
    if MapSet.member?(seen, app) do
      grow(reverse, rest, seen)
    else
      grow(reverse, Map.get(reverse, app, []) ++ rest, MapSet.put(seen, app))
    end
  end

  defp umbrella_app?(dir) do
    parent = Path.dirname(dir)

    Path.basename(parent) == "apps" and app_dir?(dir) and
      umbrella_root?(Path.dirname(parent))
  end

  # An umbrella's root `mix.exs` sets `apps_path:`. We *parse* the source and look
  # for the keyword key rather than evaluate it — Mutare runs outside the target's
  # Mix and must not execute target build code to classify a directory (and Mix has
  # no API that reads a project file without evaluating it). Parsing keeps the check
  # static while ignoring `apps_path:` in comments, strings, or docs.
  defp declares_apps_path?(mix_exs) do
    with {:ok, source} <- File.read(mix_exs),
         {:ok, ast} <- Code.string_to_quoted(source) do
      {_ast, found} =
        Macro.prewalk(ast, false, fn
          {:apps_path, _value} = node, _found -> {node, true}
          node, found -> {node, found}
        end)

      found
    else
      _ -> false
    end
  end
end
