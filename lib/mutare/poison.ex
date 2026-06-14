defmodule Mutare.Poison do
  @moduledoc """
  Identify compile-poisoning mutants from a failed metamutant compile.

  Every mutated branch lives in the one build, so a single mutation that won't
  compile would sink the whole run. Built-in mutators are compile-safe by
  construction, but a custom mutator can emit something that doesn't (an unbound
  variable, an undefined local call, …). Rather than abort, the runner asks this
  module which mutant ids the compile error points at, drops them, and rebuilds.

  We map each error's `file:line` to the mutant id whose selector clause body
  sits on that line (by re-parsing the metamutant). The poison is always in a
  mutant clause — the catch-all is the original, which compiled.
  """

  @key Mutare.Selector.key()

  @doc """
  Mutant ids implicated by `compile_output`, given `%{file => metamutant source}`.
  Returns an empty set when nothing could be mapped (the caller then aborts).
  """
  @spec ids(String.t(), %{optional(String.t()) => String.t()}) :: MapSet.t()
  def ids(compile_output, metamutants) do
    compile_output
    |> error_locations()
    |> Enum.flat_map(fn {file, line} ->
      case Map.fetch(metamutants, file) do
        {:ok, source} -> ids_at_line(source, line)
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

  defp ids_at_line(source, line) do
    {_ast, ids} =
      source
      |> Code.string_to_quoted!(columns: true)
      |> Macro.prewalk([], fn
        {:case, _meta, [subject, [do: clauses]]} = node, acc ->
          if selector?(subject),
            do: {node, acc ++ ids_in_clauses(clauses, line)},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    ids
  end

  defp ids_in_clauses(clauses, line) do
    for {:->, _, [[id], body]} <- clauses, is_integer(id), node_line(body) == line, do: id
  end

  defp selector?({{:., _, [:persistent_term, :get]}, _, [key | _]}), do: key == @key
  defp selector?(_), do: false

  defp node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp node_line(_), do: nil
end
