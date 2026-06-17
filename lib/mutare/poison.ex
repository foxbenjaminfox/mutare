defmodule Mutare.Poison do
  @moduledoc """
  Identify compile-poisoning mutants from a failed metamutant compile.

  Every mutated branch lives in the one build, so a single mutation that won't
  compile would sink the whole run. Built-in mutators are compile-safe by
  construction, but a custom mutator can emit something that doesn't (an unbound
  variable, an undefined local call, …). Rather than abort, the runner asks this
  module which mutant ids the compile error points at, drops them, and rebuilds.

  We map each error's `file:line` to the mutant id(s) whose *generated code*
  spans that line, via a `Mutare.Manifest` built on demand from the file's
  rendered metamutant (see `Manifest.ids_at_line/2`). The manifest records the
  full line range of every mutant's generated code — its selector clause body,
  and for a lifted mutant the gated clause (`when mutare_active === <id>`) where its
  guard/head-pattern code actually lives — so a poison is found whether the error
  points at the clause, a later line of a multiline body, a lifted mutant clause, or
  (as a coarse fallback) the surrounding `case`. Matching only the selector clause's
  *start line*, as we used to, missed all but the first of those.

  The manifest is built **here, lazily**, only for the file(s) a compile error
  names — not eagerly for every mutated file during the scan. That eager build
  was pure waste: a manifest is read only on a failed compile (rare — built-in
  mutators are compile-safe), yet a full `Sourceror.parse_string!` of a large
  metamutant is by far the most expensive step of the scan (a 1500-line source
  whose metamutant is ~40k lines took *minutes* to re-parse). Deferring it to the
  poison path removes that cost from every healthy run.

  Returns an empty set when nothing could be mapped (the caller then aborts).
  """

  alias Mutare.Manifest

  @doc """
  Mutant ids implicated by `compile_output`, given `%{file => metamutant_source}`.

  Builds the per-file `Mutare.Manifest` lazily — only for the file(s) an error
  names — and memoizes it across error locations, so a file faulting on several
  lines is parsed once. Returns an empty set when nothing could be mapped (the
  caller then aborts).
  """
  @spec ids(String.t(), %{optional(String.t()) => String.t()}) :: MapSet.t()
  def ids(compile_output, metamutants) do
    {ids, _cache} =
      compile_output
      |> error_locations()
      |> Enum.flat_map_reduce(%{}, fn {file, line}, cache ->
        case manifest_for(file, metamutants, cache) do
          {nil, cache} -> {[], cache}
          {manifest, cache} -> {Manifest.ids_at_line(manifest, line), cache}
        end
      end)

    MapSet.new(ids)
  end

  # The manifest for `file`, built once from its stored metamutant source and
  # memoized in `cache`. A `nil` (file not in the map) is cached too, so a stray
  # error line in an untracked file isn't re-resolved.
  defp manifest_for(file, metamutants, cache) do
    case cache do
      %{^file => manifest} ->
        {manifest, cache}

      _ ->
        manifest =
          case Map.fetch(metamutants, file) do
            {:ok, source} -> Manifest.from_source(source)
            :error -> nil
          end

        {manifest, Map.put(cache, file, manifest)}
    end
  end

  # `file:line` pairs from compiler output, e.g. `lib/foo.ex:5:12` or `lib/foo.ex:5`.
  defp error_locations(output) do
    ~r{([\w/.\-]+\.exs?):(\d+)}
    |> Regex.scan(output)
    |> Enum.map(fn [_match, file, line] -> {file, String.to_integer(line)} end)
    |> Enum.uniq()
  end
end
