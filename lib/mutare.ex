defmodule Mutare do
  @moduledoc """
  Mutare is a mutation testing system for Elixir, that mutates the source you actually write, and compiles **once**.

  The whole project is downstream of one invariant: **compile once**. Mutare
  rewrites a project's source into a *metamutant* — a single program that embeds
  every mutant behind a `:persistent_term` runtime switch — compiles it once,
  then runs the suite once per mutant by flipping `MUTANT_UNDER_TEST`.

  On top of that, the runner adds coverage-guided test selection, compile-poison
  recovery, parallel execution, timeouts, ignore annotations, and changed-file
  scoping via `--since`.

  Most users drive Mutare through the `mix mutare` task; `run/2` is the
  programmatic entry point and `transform_string/2` exposes the source rewrite on
  its own. See `Mutare.Runner` for the run flow and `Mutare.Mutator` for writing
  your own mutators.
  """

  @doc """
  Transform a source string into `{metamutant_source, [%Mutare.Site{}], next_id}`.

      iex> source = "defmodule Calculator do\\n  def add(a, b), do: a + b\\nend\\n"
      iex> {_metamutant, [site], next_id} = Mutare.transform_string(source, mutators: [:arithmetic])
      iex> {site.id, site.mutator, site.original_code, site.mutated_code, next_id}
      {1, :arithmetic, "a + b", "a - b", 2}
  """
  defdelegate transform_string(source, opts \\ []), to: Mutare.Transform

  @doc "Run mutation testing against the project at `root`. See `Mutare.Runner.run/2`."
  defdelegate run(root \\ ".", opts \\ []), to: Mutare.Runner
end
