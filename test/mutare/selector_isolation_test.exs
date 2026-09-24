defmodule Mutare.SelectorIsolationTest do
  # Every test metamutant numbers its mutants from 1, and the mutant selector is
  # `:persistent_term` state, so a test module that selects concurrently on a key another
  # module also reads leaks its selection into that module's *baseline* calls, intermittently.
  # `Mutare.Test` gives each test module a private key (`isolate_selector/0`): its helpers
  # take it before they transform or select, so a module that only ever transforms through
  # them is safe `async: true`. One that transforms through `Mutare.Transform` itself bakes
  # whatever key is in force at that moment, so it must call `isolate_selector/0` first — in a
  # `setup`, ahead of the first transform. This enforces that over the suite's own source, and
  # keeps the coverage recorder's track flag, which stays VM-wide, to serial modules.
  use ExUnit.Case, async: true

  @selecting ~r/\b(with_active_mutant|observe_mutant|Selector\.put)\b/
  @transforming ~r/\bTransform\.transform_string(_with_sites)?\(/
  @isolating ~r/\bisolate_selector\(\)/
  @tracking ~r/persistent_term\.put\(\s*(Recorder\.)?track_key\(\)/

  test "an async module that transforms itself and selects takes its private key first" do
    offenders =
      for {file, module, body} <- async_modules(),
          body =~ @selecting,
          body =~ @transforming,
          not (body =~ @isolating),
          do: "#{file}: #{module}"

    assert offenders == []
  end

  test "no async module sets the coverage track flag" do
    offenders =
      for {file, module, body} <- async_modules(), body =~ @tracking, do: "#{file}: #{module}"

    assert offenders == []
  end

  defp async_modules do
    for file <- Path.wildcard(Path.join(__DIR__, "**/*_test.exs")),
        file != __ENV__.file,
        {module, body} <- test_modules(File.read!(file)),
        body =~ ~r/use ExUnit\.Case,\s*async: true/,
        do: {Path.relative_to_cwd(file), module, body}
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
