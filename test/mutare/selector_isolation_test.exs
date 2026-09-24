defmodule Mutare.SelectorIsolationTest do
  # Every test metamutant numbers its mutants from 1, and the mutant selector is
  # `:persistent_term` state, so a test module that selects concurrently on a key another
  # module also reads leaks its selection into that module's *baseline* calls, intermittently.
  # `Mutare.Test` gives each test module a private key (`isolate_selector/0`): its helpers
  # take it before they transform or select, so a module that only ever transforms through
  # them is safe `async: true`. One that transforms through `Mutare.Transform` itself bakes
  # whatever key is in force at that moment, so it must call `isolate_selector/0` first — in a
  # `setup`, ahead of the first transform. This enforces that over the suite's own source, and
  # keeps the coverage recorder's track flag, which stays VM-wide, to serial modules. That
  # the key is private to a module *execution* — two `:parameterize` instances apart — is
  # `selector_isolation_execution_test.exs`.
  use ExUnit.Case, async: true
  import Mutare.Test

  alias Mutare.Selector

  @selecting ~r/\b(with_active_mutant|observe_mutant|Selector\.put)\b/
  @transforming ~r/\bTransform\.transform_string(_with_sites)?\(/
  @isolating ~r/\bisolate_selector\b/
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

  # The walk for the module runner is bounded, so a process far enough below the test is
  # one it cannot reach — as a process started under a supervisor is. Under ExUnit that is
  # not a fallback to the shared key but a failure, and the remedy is the key itself.
  test "a process the walk cannot reach is refused the shared key, and takes the given one" do
    key = isolate_selector()

    assert {:error, %RuntimeError{message: message}} = deep(7, &isolate_selector/0)
    assert message =~ "no ExUnit test runs above this process"

    assert {:ok, ^key} =
             deep(7, fn ->
               Process.put(Selector.process_key(), key)
               isolate_selector()
             end)
  end

  # `fun` in a process `depth` spawns below this one, its result or exception.
  defp deep(0, fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  end

  defp deep(depth, fun), do: Task.async(fn -> deep(depth - 1, fun) end) |> Task.await()

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
