defmodule Mutare do
  @moduledoc """
  Mutare — mutation testing for Elixir built on a single compilation.

  The whole project is downstream of one invariant: **compile once**. Mutare
  rewrites a project's source into a *metamutant* — a single program that embeds
  every mutant behind a `:persistent_term` runtime switch — compiles it once,
  then runs the suite once per mutant by flipping `MUTANT_UNDER_TEST`.

  M1 (walking skeleton) wires up the in-place selector for arithmetic and
  relational mutators end to end. See `Mutare.Transform` for the rewrite and
  `Mutare.Selector` for runtime selection.
  """

  @doc "Transform a source string into `{metamutant_source, [%Mutare.Site{}], next_id}`."
  defdelegate transform_string(source, opts \\ []), to: Mutare.Transform

  @doc "Run mutation testing against the project at `root`. See `Mutare.Runner.run/2`."
  defdelegate run(root \\ ".", opts \\ []), to: Mutare.Runner
end
