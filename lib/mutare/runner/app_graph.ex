defmodule Mutare.Runner.AppGraph do
  @moduledoc """
  Read an umbrella's **declared** inter-app dependency graph out of the sandbox.

  `Mutare.Project.app_test_scopes/3` narrows a broad (whole-umbrella) mutant run
  to the mutant's owning app plus its transitive dependents, which needs the
  forward graph `%{app => [sibling apps it depends on]}`. This module gets it from
  Mix: one `mix eval` in the sandbox (no compile, no deps check) merges
  `Mix.Project.deps_tree/0` from the umbrella root with sibling applications named
  by each child's `application/0`. Every child's `deps/0` and `application/0` are
  evaluated under `MIX_ENV=test` exactly as the test runs see them. Consequently,
  a `runtime: false` sibling and one named only through `:extra_applications` or
  explicit `:applications` all count as dependencies, while an `only:` that
  excludes the test env does not. Why the graph is read this way rather than only
  off the build: NOTES "Umbrella narrowing must follow the declared graph".

  ## Output contract

  The evaluated snippet prints one `mutare-dep <app> <dep> <dep>…` line per node
  of the tree and a closing `mutare-dep-end` line. `parse/2` keeps the lines
  naming an umbrella app, drops deps that aren't umbrella apps (Hex packages),
  matches names as strings against the *known* app list (never `String.to_atom/1`
  on subprocess output), and is `:error` unless every umbrella app was reported
  and the end marker arrived — a missing node would silently lose that app's
  edges, so any incompleteness means "unknown graph" and the caller runs the
  whole umbrella.
  """

  alias Mutare.Project
  alias Mutare.Sandbox.Command.{Exit, Invocation}
  alias Mutare.Selector

  require Logger

  @typedoc "The declared forward graph over umbrella apps: `%{app => [apps it depends on]}`."
  @type forward :: %{atom() => [atom()]}

  @sentinel "mutare-dep"
  @end_marker "mutare-dep-end"

  @snippet """
  paths = Mix.Project.apps_paths()

  for {app, deps} <- Mix.Project.deps_tree() do
    application_deps =
      case Map.fetch(paths, app) do
        {:ok, path} ->
          Mix.Project.in_project(app, path, fn project ->
            application =
              if function_exported?(project, :application, 0),
                do: project.application(),
                else: []

            Keyword.get(application, :applications, []) ++
              Keyword.get(application, :extra_applications, [])
          end)

        :error ->
          []
      end

    merged = Enum.uniq(deps ++ application_deps)
    IO.puts(Enum.join(["#{@sentinel}", app | merged], " "))
  end

  IO.puts("#{@end_marker}")
  """

  # The one compile already happened and the deps are seeded, so skip every check
  # that would cost a walk (or fail for a reason that doesn't affect the graph).
  @args [
    "eval",
    "--no-compile",
    "--no-deps-check",
    "--no-archives-check",
    "--no-elixir-version-check",
    @snippet
  ]

  @doc """
  The declared graph of `project`'s umbrella apps, read from the sandbox.

  A single (non-umbrella) project is `{:ok, %{}}` without running anything. For an
  umbrella, a failed `mix eval` or an incomplete tree (see `parse/2`) is `:error`
  — logged, since the fallback (every broad run covers the whole umbrella) is
  safe but slow.
  """
  @spec read(Project.t(), Path.t()) :: {:ok, forward()} | :error
  def read(%Project{umbrella?: true, apps: apps}, sandbox) do
    names = Enum.map(apps, & &1.app)
    {output, status} = Invocation.mix(sandbox, @args, Selector.baseline())

    if Exit.success?(status) do
      case parse(output, names) do
        {:ok, forward} -> {:ok, forward}
        :error -> degrade(output, "incomplete dependency tree in the mix eval output")
      end
    else
      degrade(output, "mix eval exited with status #{status}")
    end
  end

  def read(%Project{}, _sandbox), do: {:ok, %{}}

  @doc """
  Decode `mix eval` output (see the module doc's output contract) into the forward
  graph over `names`, the known umbrella apps.
  """
  @spec parse(String.t(), [atom()]) :: {:ok, forward()} | :error
  def parse(output, names) do
    by_name = Map.new(names, &{Atom.to_string(&1), &1})
    lines = String.split(output, ["\r\n", "\n"])

    forward =
      for line <- lines,
          [@sentinel, app | deps] <- [String.split(line, " ", trim: true)],
          {:ok, name} <- [Map.fetch(by_name, app)],
          into: %{} do
        {name, deps |> Enum.map(&Map.get(by_name, &1)) |> Enum.reject(&is_nil/1)}
      end

    if @end_marker in lines and Enum.all?(names, &Map.has_key?(forward, &1)),
      do: {:ok, forward},
      else: :error
  end

  defp degrade(output, why) do
    Logger.warning(
      "Mutare: could not read the umbrella dependency graph (#{why}); " <>
        "broad mutant runs will run every app.\n" <> String.trim_trailing(output)
    )

    :error
  end
end
