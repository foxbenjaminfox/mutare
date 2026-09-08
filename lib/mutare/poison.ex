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
  rendered metamutant (see `Manifest.ids_at_line/2`). Only *error* diagnostics are
  scanned, never warnings: a failed compile prints every warning the mutations
  provoke (each footered with the same `file:line` shape), and mistaking those for
  the error's location dropped valid mutants as false poison (see `error_locations/1`).
  The manifest records the
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

  When line attribution maps nothing — the signature of an *inline* DSL macro that rejects
  the spliced selector, where the compiler blames the macro-*call* line no manifest region
  covers — the runner falls back to `macro_poison/2`, which attributes by the macro *name*
  the compiler blamed (via `Mutare.Manifest.ids_in_named_calls/2`) instead of by line. Only
  when *both* fail does the run abort.

  A schema metamutant contains local integer ids. The runner supplies
  `Mutare.RuntimeId.file_index(schema.sites)` to `ids/3` and `macro_poison/3` so
  attribution translates `{file, local_id}` to report ids before merging files.
  Without an index these APIs return the integers read from the metamutant, as
  used by standalone transforms. The macro fallback retains the call-site file
  through that conversion; two files' local id 1 must never collapse together.
  """

  alias Mutare.Manifest
  alias Mutare.Poison.Hint
  alias Mutare.Sandbox.Command.Output

  # The stacktrace marker separating a macro's expansion frames (above) from its call site
  # (the next source-location frame below). Co-located with the call-site scan it drives.
  @expanding_macro ~r/expanding macro:/

  @doc """
  The **macro-expansion fallback** attribution: mutant ids that live inside a call to a
  macro the compiler blamed, grouped by that macro.

  When a mutation splices a runtime selector `case` into an argument that a macro rewrites
  at compile time (an `Ecto.Query.from/2`-style inline DSL, a macro needing a literal), the
  macro raises *while expanding* and the compiler blames the **macro-call line** — one line
  above the selector `case` the `Mutare.Manifest` knows about — so `ids/2` finds nothing and
  the run would abort. But the failure output names the culprit in an `expanding macro:
  Mod.fun/arity` frame (`Hint.expanding_macros/1`). This maps that name back to mutant ids
  through the **metamutant** (`Manifest.ids_in_named_calls/2`): find every call of that name in
  the rendered metamutant of the file(s) the error touches, and collect the ids inside its
  span. Bare-name match (the call is usually an imported `from(...)`, not `Ecto.Query.from`),
  so two same-named macros are skipped together — conservative, and one of them did raise.

  Attributing through the metamutant + manifest (not the schema's `:sites`) is deliberate, and
  for the same reason as the line-based `ids/2` it backs up: this is positional work in
  **metamutant** space — spans of the rendered source the compiler actually read — which
  `:sites`, recorded in *original*-source coordinates, cannot answer.

  Returns `[{{module_string, fun_atom}, MapSet.t()}]` — one entry per blamed macro that
  matched at least one mutant — so the caller can drop the union and name each macro for the
  narration and the `{Module, :fun, :raw}` suggestion.
  """
  @spec macro_poison(String.t(), %{optional(String.t()) => String.t()}, map() | nil) ::
          [{{String.t(), atom()}, MapSet.t()}]
  def macro_poison(compile_output, metamutants, report_ids \\ nil) do
    macros = Hint.expanding_macros(compile_output)
    names = MapSet.new(macros, fn {_module, fun} -> fun end)

    ids_by_name =
      compile_output
      |> candidate_files(metamutants)
      |> Enum.reduce(%{}, fn {file, source}, acc ->
        ids =
          Map.new(Manifest.ids_in_named_calls(source, names), fn {name, ids} ->
            {name, MapSet.new(translate(ids, file, report_ids))}
          end)

        merge_ids(acc, ids)
      end)

    macros
    |> Enum.map(fn {_module, fun} = macro ->
      {macro, Map.get(ids_by_name, fun, MapSet.new())}
    end)
    |> Enum.reject(fn {_macro, ids} -> Enum.empty?(ids) end)
  end

  # The metamutant sources of the macro **call-site** file(s) — the source location on the frame
  # that *follows* each `expanding macro:` marker. Deliberately not every `error_locations/1`
  # file: a macro defined in the target project also puts frames from its *implementation* file
  # (and Elixir internals) on the stack, *before* the marker; scanning those would drop valid
  # mutants in an unrelated same-named call there as poison. A call-site file we didn't render
  # (a dependency) is dropped.
  defp candidate_files(output, metamutants) do
    output
    |> call_site_files()
    |> Enum.uniq()
    |> Enum.flat_map(fn file ->
      case Map.fetch(metamutants, file) do
        {:ok, source} -> [{file, source}]
        :error -> []
      end
    end)
  end

  # The file on the first source-location frame after each `expanding macro:` line — the site
  # that invoked the macro. Frames *before* the marker are the macro's own expansion (its impl
  # file + Elixir internals) and are ignored.
  defp call_site_files(output) do
    {_armed?, files} =
      output
      |> String.split("\n")
      |> Enum.reduce({false, []}, fn line, {armed?, files} ->
        cond do
          Regex.match?(@expanding_macro, line) -> {true, files}
          armed? -> arm_call_site(line, files)
          true -> {false, files}
        end
      end)

    Enum.reverse(files)
  end

  # Once armed by an `expanding macro:` marker, the next line carrying a source location is the
  # call site: record its file and disarm. A non-location line (the marker's own blank/chatter)
  # keeps us armed until the frame arrives.
  defp arm_call_site(line, files) do
    case Regex.run(Output.source_location_regex(), line) do
      [_match, file, _num] -> {false, [file | files]}
      _ -> {true, files}
    end
  end

  defp merge_ids(acc, ids_by_name),
    do: Map.merge(acc, ids_by_name, fn _name, a, b -> MapSet.union(a, b) end)

  @doc """
  Mutant ids implicated by `compile_output`, given `%{file => metamutant_source}`.

  Builds the per-file `Mutare.Manifest` lazily — only for the file(s) an error
  names — and memoizes it across error locations, so a file faulting on several
  lines is parsed once. Returns an empty set when nothing could be mapped (the
  caller then aborts).
  """
  @spec ids(String.t(), %{optional(String.t()) => String.t()}, map() | nil) :: MapSet.t()
  def ids(compile_output, metamutants, report_ids \\ nil) do
    {ids, _cache} =
      compile_output
      |> error_locations()
      |> Enum.flat_map_reduce(%{}, fn {file, line}, cache ->
        case manifest_for(file, metamutants, cache) do
          {nil, cache} ->
            {[], cache}

          {manifest, cache} ->
            {translate(Manifest.ids_at_line(manifest, line), file, report_ids), cache}
        end
      end)

    MapSet.new(ids)
  end

  defp translate(ids, _file, nil), do: ids
  defp translate(ids, file, report_ids), do: Enum.map(ids, &Map.fetch!(report_ids, {file, &1}))

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

        # This branch only runs when `file` is absent from `cache` (the sibling clause above
        # matches when present), so `Map.put_new/3` inserts identically here; `Map.replace/3`
        # would just skip the insert, forcing every later duplicate-file error to retake this
        # branch and recompute `Manifest.from_source` (a pure, deterministic parse) — a real
        # efficiency loss, but unobservable in `ids/2`'s returned `MapSet` (the only thing a
        # black-box test can assert on).
        # mutare:ignore[map_keyword] equivalent, per above
        {manifest, Map.put(cache, file, manifest)}
    end
  end

  # `file:line` pairs from compiler output, e.g. `lib/foo.ex:5:12` or `lib/foo.ex:5`.
  # The pattern is owned by `Mutare.Sandbox.Command` (the home of everything that
  # parses mix's output), so a mix output-format change is a single fix there.
  #
  # We scan only the lines that aren't inside a *warning* diagnostic. A failed
  # metamutant compile prints the one real error alongside every warning the mutations
  # provoke — and mix footers warnings with the very same `└─ file:line:col:` reference
  # this pattern matches. Scanning the whole output mapped those benign warning lines
  # (`unused variable` from a mutant forcing a guard to `true`, `cannot match` from a
  # widened clause) onto unrelated mutant ids and dropped valid mutants as false poison:
  # on plug, one real error dragged ~110 good mutants down with it. So we thread each
  # line's severity (`Output.diagnostic_severity/1`) and skip warning blocks — keeping
  # the real error's own footer, which lives outside any warning block.
  defp error_locations(output) do
    output
    |> error_text_lines()
    |> Enum.flat_map(fn line ->
      Output.source_location_regex()
      |> Regex.scan(line)
      |> Enum.map(fn [_match, file, num] -> {file, String.to_integer(num)} end)
    end)
    # `ids/2` folds this list straight into a `MapSet` (order- and duplicate-insensitive), so
    # deduping here only avoids redundant (but pure, deterministic) `manifest_for`/`ids_at_line`
    # lookups; the returned set is identical either way.
    # mutare:ignore[call_removal] equivalent, per above
    |> Enum.uniq()
  end

  # The output lines that are *not* part of a warning diagnostic. Severity defaults to
  # `:error` (so error footers, exception lines, and chatter — none of which carry a
  # misleading location — are kept) and flips to `:warning` only inside a `warning:`
  # block, until the next `error:`/`** (…Error)` header flips it back. This is a strict
  # narrowing of "scan everything": it can only *remove* warning lines, never lose the
  # real error's location.
  defp error_text_lines(output) do
    output
    |> String.split("\n")
    # Only `severity == :warning` is ever tested below; any non-`:warning` initial sentinel
    # (this starts before the first line, so it can't itself *be* a warning) behaves
    # identically, and `severity` itself is dropped by `elem(1)` right after the reduce.
    # mutare:ignore[convention] equivalent, per above
    |> Enum.reduce({:error, []}, fn line, {severity, kept} ->
      severity = Output.diagnostic_severity(line) || severity
      {severity, if(severity == :warning, do: kept, else: [line | kept])}
    end)
    |> elem(1)
    # Same reasoning as the `Enum.uniq()` above: `error_locations/1`'s caller only ever folds
    # the file:line pairs extracted from these lines into a `MapSet` (order-insensitive), so
    # reversing back to document order here has no observable effect on `ids/2`'s result. Kept
    # for the (untested) documentation value of returning lines in source order to any other
    # future caller.
    # mutare:ignore[call_removal, collection_arity] equivalent, per above
    |> Enum.reverse()
  end
end
