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

  defp umbrella_app?(dir) do
    parent = Path.dirname(dir)

    Path.basename(parent) == "apps" and app_dir?(dir) and
      umbrella_root?(Path.dirname(parent))
  end

  # A cheap, dependency-free read: an umbrella's root `mix.exs` sets `apps_path:`.
  # We match the source text rather than evaluate it (Mutare runs outside the
  # target's Mix, and must not execute target build code to classify a directory).
  defp declares_apps_path?(mix_exs) do
    case File.read(mix_exs) do
      {:ok, source} -> Regex.match?(~r/\bapps_path:/, source)
      _ -> false
    end
  end
end
