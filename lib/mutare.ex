defmodule Mutare do
  @moduledoc """
  Mutare — mutation testing for Elixir built on a single compilation.

  The whole project is downstream of one invariant: **compile once**. Mutare
  rewrites a project's source into a *metamutant* — a single program that embeds
  every mutant behind a `:persistent_term` runtime switch — compiles it once,
  then runs the suite once per mutant by flipping `MUTANT_UNDER_TEST`.

  Body mutations use in-place selectors, while guard and clause mutations use
  function lifting and dispatchers. The runner adds coverage-guided test
  selection, compile-poison recovery, parallel execution, timeouts, ignore
  annotations, and changed-file scoping via `--since`.

  See `Mutare.Transform` for source rewriting and `Mutare.Runner` for execution.
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
