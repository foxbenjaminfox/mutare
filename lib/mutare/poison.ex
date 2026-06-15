defmodule Mutare.Poison do
  @moduledoc """
  Identify compile-poisoning mutants from a failed metamutant compile.

  Every mutated branch lives in the one build, so a single mutation that won't
  compile would sink the whole run. Built-in mutators are compile-safe by
  construction, but a custom mutator can emit something that doesn't (an unbound
  variable, an undefined local call, …). Rather than abort, the runner asks this
  module which mutant ids the compile error points at, drops them, and rebuilds.

  We map each error's `file:line` to the mutant id(s) whose *generated code*
  spans that line, using the stored `Mutare.Manifest` (see `Manifest.ids_at_line/2`).
  The manifest records the full line range of every mutant's generated code — its
  selector clause body, and for a lifted mutant the private `defp` copies where its
  guard/clause-drop code actually lives — so a poison is found whether the error
  points at the clause, a later line of a multiline body, a lifted private
  definition, or (as a coarse fallback) the surrounding `case`. Matching only the
  selector clause's *start line*, as we used to, missed all but the first of those.

  Returns an empty set when nothing could be mapped (the caller then aborts).
  """

  alias Mutare.Manifest

  @doc """
  Mutant ids implicated by `compile_output`, given `%{file => Mutare.Manifest}`.
  Returns an empty set when nothing could be mapped (the caller then aborts).
  """
  @spec ids(String.t(), %{optional(String.t()) => Manifest.t()}) :: MapSet.t()
  def ids(compile_output, manifests) do
    compile_output
    |> error_locations()
    |> Enum.flat_map(fn {file, line} ->
      case Map.fetch(manifests, file) do
        {:ok, manifest} -> Manifest.ids_at_line(manifest, line)
        :error -> []
      end
    end)
    |> MapSet.new()
  end

  # `file:line` pairs from compiler output, e.g. `lib/foo.ex:5:12` or `lib/foo.ex:5`.
  defp error_locations(output) do
    ~r{([\w/.\-]+\.exs?):(\d+)}
    |> Regex.scan(output)
    |> Enum.map(fn [_match, file, line] -> {file, String.to_integer(line)} end)
    |> Enum.uniq()
  end
end
