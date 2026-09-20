defmodule Mutare.Poison do
  @moduledoc """
  Identify compile-poisoning mutants from a failed metamutant compile.

  Every mutated branch is included in one build, so a single mutation that won't
  compile would prevent the whole run. Built-in mutators are compile-safe by
  construction, but a custom mutator can emit something that doesn't (an unbound
  variable, an undefined local call, …). The runner uses this module to identify
  the mutant ids at the error location, then drops them and rebuilds.

  We map each error's `file:line` to the mutant id(s) whose *generated code*
  spans that line, via a `Mutare.Manifest` built on demand from the file's
  rendered metamutant and the dispatch variable its generated code reads
  (`Mutare.Schema`'s `:metamutants` and `:dispatch_vars`; see
  `Manifest.ids_at_line/2`). Only *error* diagnostics are
  scanned, never warnings: compiler output also includes warnings caused by mutations
  (each with a footer in the same `file:line` format), and mistaking those for
  the error's location dropped valid mutants as false poison (see `error_locations/1`).
  The manifest records the
  full line range of every mutant's generated code — its selector clause body,
  and for a lifted mutant the gated clause (`when mutare_active === <id>`) where its
  guard/head-pattern code appears — so a poison is found whether the error
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
  the spliced selector, where the compiler reports an error on the macro-*call* line no manifest region
  covers — the runner falls back to `macro_poison/4`, which attributes by the macro *name*
  in the compiler output (via `Mutare.Manifest.ids_in_named_calls/2`) instead of by line. Only
  when *both* fail does the run abort. The runner obtains both results through `attribution/4`,
  which builds each file's manifest once for the round; `ids/4` and `macro_poison/4` are
  the two halves on their own.

  An error can also land in a **clean region's uninstrumented copy**
  (`Mutare.Transform.CleanRegion`), which belongs to no mutant: the transform copies any
  source without asking whether it survives the copy (a macro may refuse to expand twice, or
  under a relocated name). `attribution/4` reports those regions under `:clean`, as
  `{file, range}` — the identity the region's own guard carries — and the runner drops them
  through `Mutare.Schema`'s `skip_regions`. A macro that raises inside a clean copy is
  excluded from the macro fallback: there is no selector in a copy for it to have rejected,
  so its mutants elsewhere in the file are not the cause.

  A schema metamutant contains local integer ids. The runner supplies
  `Mutare.RuntimeId.file_index(schema.sites)` so attribution translates `{file, local_id}`
  to report ids before merging files. Without an index these APIs return the integers read
  from the metamutant, as used by standalone transforms. The macro fallback retains the
  call-site file through that conversion; two files' local id 1 must never collapse together.
  An id absent from the index corresponds to no mutant in this run — a file the selection left with
  nothing to emit renders pristine, and pristine source can imitate a selector — so it is
  dropped, degrading to "mapped nothing" rather than crashing a run mid-recovery.
  """

  alias Mutare.Manifest
  alias Mutare.Poison.Hint
  alias Mutare.Sandbox.Command.Output

  @typedoc "The rendered metamutants of a build, by root-relative file."
  @type metamutants :: %{optional(String.t()) => String.t()}

  @typedoc """
  Each rendered file's dispatch variable (`Mutare.Transform.Result.dispatch_var`), by
  root-relative file. Every file in `t:metamutants/0` must have one.
  """
  @type dispatch_vars :: %{optional(String.t()) => atom()}

  @typedoc """
  The macro-expansion fallback's matches: `{{module_string, fun_atom}, ids}` per implicated macro
  that matched at least one mutant, in first-seen order.
  """
  @type macro_matches :: [{{String.t(), atom()}, MapSet.t()}]

  # One manifest per file, built on first need and reused for the rest of a round. `nil`
  # marks a file not in the metamutant map (a dependency, an untracked location), so a
  # repeated stray reference isn't re-resolved either.
  @typep manifests :: %{optional(String.t()) => Manifest.t() | nil}

  @typedoc "A clean region, by its file and the id interval its guard carries."
  @type clean_region :: {String.t(), Manifest.clean_range()}

  @doc """
  Every attribution of one failed compile — `%{line: ids, macro: matches, clean: regions}`:
  the results of `ids/4` and `macro_poison/4`, and the clean regions whose uninstrumented
  copy an error line falls in — from one manifest per file.

  The runner's poison-recovery loop uses both every round (macro attribution takes priority,
  with line attribution as a fallback). The macro's call-site file is normally also listed
  in the error's source locations. With a shared cache, each such metamutant is parsed and
  ranged once per round, not once per attribution.
  """
  @spec attribution(String.t(), metamutants(), dispatch_vars(), map() | nil) ::
          %{line: MapSet.t(), macro: macro_matches(), clean: MapSet.t(clean_region())}
  def attribution(compile_output, metamutants, dispatch_vars, report_ids \\ nil) do
    {line, clean, manifests} =
      line_attribution(compile_output, metamutants, dispatch_vars, report_ids, %{})

    {macro, _manifests} =
      macro_attribution(compile_output, metamutants, dispatch_vars, report_ids, manifests)

    %{line: line, macro: macro, clean: clean}
  end

  @doc """
  The **macro-expansion fallback** attribution: mutant ids inside calls to macros
  listed in the compiler's expansion stack, grouped by macro.

  When a mutation splices a runtime selector `case` into an argument that a macro rewrites
  at compile time (an `Ecto.Query.from/2`-style inline DSL, a macro needing a literal), the
  macro raises *while expanding* and the compiler reports the **macro-call line** — one line
  above the selector `case` recorded in `Mutare.Manifest` — so `ids/4` finds nothing and
  the run would abort. The failure output identifies the macro in an `expanding macro:
  Mod.fun/arity` frame, followed by the location that invoked it (`Hint.culprits/1`). This
  maps that name back to mutant ids through the **metamutant** of that call-site file
  (`Manifest.ids_in_named_calls/2`): find every call of the name in the rendered source and
  collect the ids inside its span. Bare-name match (the call is usually an imported
  `from(...)`, not `Ecto.Query.from`), so two same-named macros in the file are skipped
  together — conservative, and one of them did raise.

  Only the call-site file is searched — deliberately not every file the error located: a
  macro defined in the target project also puts frames from its *implementation* file (and
  Elixir internals) on the stack, and scanning those would drop valid mutants in an unrelated
  same-named call there as poison. A call site we didn't render (a dependency), or a frame
  with no location, attributes nothing.

  Attributing through the metamutant + manifest (not the schema's `:sites`) is deliberate, and
  for the same reason as the line-based `ids/4` it backs up: this is positional work in
  **metamutant** space — spans of the rendered source the compiler actually read — which
  `:sites`, recorded in *original*-source coordinates, cannot answer.

  Returns one `{{module_string, fun_atom}, ids}` entry per implicated macro that matched at least
  one mutant, so the caller can drop the union and name each macro in the diagnostic and the
  `{Module, :fun, :raw}` suggestion.
  """
  @spec macro_poison(String.t(), metamutants(), dispatch_vars(), map() | nil) :: macro_matches()
  def macro_poison(compile_output, metamutants, dispatch_vars, report_ids \\ nil) do
    {matches, _manifests} =
      macro_attribution(compile_output, metamutants, dispatch_vars, report_ids, %{})

    matches
  end

  # Each culprit's name looked up in its own call-site file's manifest (built once, memoized in
  # `manifests`), ids unioned per macro; macros kept in first-seen order.
  @spec macro_attribution(String.t(), metamutants(), dispatch_vars(), map() | nil, manifests()) ::
          {macro_matches(), manifests()}
  defp macro_attribution(output, metamutants, dispatch_vars, report_ids, manifests) do
    culprits = Hint.culprits(output)

    {ids_by_macro, manifests} =
      Enum.reduce(culprits, {%{}, manifests}, fn
        {_macro, nil}, acc ->
          acc

        {{_module, fun} = macro, {file, line}}, {ids_by_macro, manifests} ->
          {manifest, manifests} = manifest_for(file, metamutants, dispatch_vars, manifests)

          ids =
            if in_clean_copy?(manifest, line),
              do: MapSet.new(),
              else: MapSet.new(translate(named_call_ids(manifest, fun), file, report_ids))

          {Map.update(ids_by_macro, macro, ids, &MapSet.union(&1, ids)), manifests}
      end)

    matches =
      culprits
      |> Enum.map(fn {macro, _call_site} -> macro end)
      |> Enum.uniq()
      |> Enum.map(&{&1, Map.get(ids_by_macro, &1, MapSet.new())})
      |> Enum.reject(fn {_macro, ids} -> Enum.empty?(ids) end)

    {matches, manifests}
  end

  # Whether the macro was invoked from a clean region's copy, which holds no selector.
  defp in_clean_copy?(nil, _line), do: false

  defp in_clean_copy?(%Manifest{} = manifest, line),
    do: Manifest.blame_at_line(manifest, line).clean != []

  # The local ids inside every call of `fun` in a rendered file; nothing for a file we didn't
  # render.
  defp named_call_ids(nil, _fun), do: []

  defp named_call_ids(%Manifest{} = manifest, fun) do
    manifest
    |> Manifest.ids_in_named_calls(MapSet.new([fun]))
    |> Map.get(fun, MapSet.new())
    |> Enum.to_list()
  end

  @doc """
  Mutant ids implicated by `compile_output`, given `%{file => metamutant_source}` and
  `%{file => dispatch_var}` (the variable each metamutant's generated code reads,
  `Mutare.Transform.Result.dispatch_var`; every file in `metamutants` must have one).

  Builds the per-file `Mutare.Manifest` lazily — only for the file(s) an error
  names — and memoizes it across error locations, so a file faulting on several
  lines is parsed once. Returns an empty set when nothing could be mapped (the
  caller then aborts).
  """
  @spec ids(String.t(), metamutants(), dispatch_vars(), map() | nil) :: MapSet.t()
  def ids(compile_output, metamutants, dispatch_vars, report_ids \\ nil) do
    {ids, _clean, _manifests} =
      line_attribution(compile_output, metamutants, dispatch_vars, report_ids, %{})

    ids
  end

  # Each error location's blame (`Manifest.blame_at_line/2`): report ids, and clean regions
  # as `{file, range}`.
  @spec line_attribution(String.t(), metamutants(), dispatch_vars(), map() | nil, manifests()) ::
          {MapSet.t(), MapSet.t(clean_region()), manifests()}
  defp line_attribution(output, metamutants, dispatch_vars, report_ids, manifests) do
    {blamed, manifests} =
      output
      |> error_locations()
      |> Enum.flat_map_reduce(manifests, fn {file, line}, manifests ->
        case manifest_for(file, metamutants, dispatch_vars, manifests) do
          {nil, manifests} ->
            {[], manifests}

          {manifest, manifests} ->
            %{ids: ids, clean: clean} = Manifest.blame_at_line(manifest, line)

            {Enum.map(translate(ids, file, report_ids), &{:id, &1}) ++
               Enum.map(clean, &{:clean, {file, &1}}), manifests}
        end
      end)

    {MapSet.new(for {:id, id} <- blamed, do: id),
     MapSet.new(for {:clean, region} <- blamed, do: region), manifests}
  end

  # Local ids read back out of a metamutant, mapped to this run's report ids. An id the index
  # doesn't know is **dropped**, never raised on: `Mutare.Schema` guarantees every emitted mutant
  # reaches a reported site, so an untranslatable id names no mutant — it is a phantom the
  # manifest read out of a file the selection left nothing to emit, which renders pristine and
  # can therefore imitate a selector in the target's own source. Attributing nothing is the
  # honest answer and the caller already handles it (macro fallback, then abort + `Hint`);
  # raising would kill a run mid-recovery from a compile failure. `Mutare.Coverage.read_dump/2`
  # degrades an unrecognised runtime id the same way. NOTES "Stable per-file runtime identities".
  defp translate(ids, _file, nil), do: ids

  defp translate(ids, file, report_ids) do
    Enum.flat_map(ids, fn id ->
      case Map.fetch(report_ids, {file, id}) do
        {:ok, report_id} -> [report_id]
        :error -> []
      end
    end)
  end

  # The manifest for `file`, built once from its stored metamutant source and dispatch
  # variable and memoized in `cache`. A `nil` (file not in the map) is cached too, so a
  # stray error line in an untracked file isn't re-resolved.
  defp manifest_for(file, metamutants, dispatch_vars, cache) do
    case cache do
      %{^file => manifest} ->
        {manifest, cache}

      _ ->
        manifest =
          case Map.fetch(metamutants, file) do
            {:ok, source} -> Manifest.from_source(source, Map.fetch!(dispatch_vars, file))
            :error -> nil
          end

        # This branch only runs when `file` is absent from `cache` (the sibling clause above
        # matches when present), so `Map.put_new/3` inserts identically here; `Map.replace/3`
        # would just skip the insert, forcing every later duplicate-file error to retake this
        # branch and recompute `Manifest.from_source` (a pure, deterministic parse) — a real
        # efficiency loss, but unobservable in `ids/4`'s returned `MapSet` (the only thing a
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
    # `ids/4` folds this list straight into a `MapSet` (order- and duplicate-insensitive), so
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
    # reversing back to document order here has no observable effect on `ids/4`'s result. Kept
    # for the (untested) documentation value of returning lines in source order to any other
    # future caller.
    # mutare:ignore[call_removal, collection_arity] equivalent, per above
    |> Enum.reverse()
  end
end
