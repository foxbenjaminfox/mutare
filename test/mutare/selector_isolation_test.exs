defmodule Mutare.SelectorIsolationTest do
  # The mutant selector is VM-wide `:persistent_term` state, and every test metamutant numbers
  # its mutants from 1. A test module that selects a mutant while running `async: true` leaks
  # that selection into whatever else is running — another test's *baseline* call then runs a
  # mutant, intermittently. `Mutare.Test.with_active_mutant/2` documents the rule; this enforces
  # it over the suite's own source.
  use ExUnit.Case, async: true

  @selecting ~r/\b(with_active_mutant|observe_mutant|Selector\.put)\b/

  test "no async test module selects a mutant" do
    offenders =
      for file <- Path.wildcard(Path.join(__DIR__, "**/*_test.exs")),
          file != __ENV__.file,
          {module, body} <- test_modules(File.read!(file)),
          body =~ ~r/use ExUnit\.Case,\s*async: true/,
          body =~ @selecting,
          do: "#{Path.relative_to_cwd(file)}: #{module}"

    assert offenders == []
  end

  # A test file's top-level modules, as `{name, source}`: split at each column-0 `defmodule`.
  defp test_modules(source) do
    ~r/^defmodule\s+([\w.]+)\s+do$/m
    |> Regex.split(source, include_captures: true, trim: true)
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [header, body] ->
        case Regex.run(~r/^defmodule\s+([\w.]+)/, header) do
          [_, name] -> [{name, body}]
          nil -> []
        end

      _preamble ->
        []
    end)
  end
end
