defmodule Mutare.Schema do
  @moduledoc """
  The mutant schema for a whole project: every in-scope source transformed into
  its metamutant, with globally-unique report ids and stable per-file runtime ids.

  This is what the runner compiles once and the report reads from.
  Files that have no mutation sites, or that *fail to parse*, are left out of
  `:metamutants` (their originals are used as-is) but never crash the build — a
  single unparseable file should not sink the run. A failure *after* a clean
  parse (transform or render) is a bug in this tool, not bad input, and is left
  to crash: see `render_one/8`.

  ## Two-phase build (`from_files/4`)

  Report ids reserve contiguous ranges in file order — file *i*'s `:start_id`
  is file *i-1*'s `next_id`. Emitted selectors instead use local integers under
  the root-relative file namespace (`Mutare.RuntimeId`). An unrelated file's
  candidate-count change therefore leaves this file's metamutant byte-identical,
  provided its source, transform inputs, and effective emission selection stay
  the same. A global cap can change that selection even with unchanged options.

  The build determines report ranges and global selection before rendering in two
  passes, both run in **throwaway worker processes** so each file's heavy,
  short-lived ASTs (the emitted tree, Sourceror's render buffers) die with their
  worker instead of accumulating in the scan's long-lived heap, where they made
  every GC scan the growing live set and inflated a big file's transform
  several-fold (see NOTES "Scan is transform-bound"):

    1. **Count** (`count_files/4`) — `Mutare.Transform.count_report/2` per file,
       in parallel. It runs the same analyze → plan → emit pipeline but skips the
       dominant final render, returning each file's mutant count and, for a line
       selection, the matching local ids (without rendering site diffs) — plus the
       *facts* the end-of-build diagnostics read (matched configuration entries, the
       comment-directive container, degraded `use`s), collected here because this
       is the one pass that parses every file: nothing later re-parses. The count
       is drift-proof: it comes from the *same* id-claiming path emission uses, so
       it equals the matching render's `next_id - start_id` by construction.
    2. **Render** (`render_files/5`) — prefix-sum the counts so each sited file
       knows its globally-unique `:start_id` up front, then
       `Mutare.Transform.transform_string/2` each file (with that `:start_id` and
       the file's `:runtime_namespace`, and the run's report-space `:skip_ids` and
       statically selected `:emit_ids`) in parallel. Every
       candidate reserves its id and records its diagnostic site, but only selected
       candidates emit branches. `render_one/8` re-checks the count
       against the rendered `next_id` and fails loudly on any drift, since id
       stability across files depends on the two passes agreeing.

  The two passes agree only because the pipeline they share — parse, `use`-expansion,
  resolution, and every mutator — is a *deterministic* function of the source and opts;
  it runs once per pass, so a nondeterministic custom mutator or extension `expand_use/3`
  surfaces as that `render_one/8` drift crash rather than a silent id overlap.
  `from_files/4` also dedups its input by relative path, so a file passed twice is
  rendered once, under one id range — never two overlapping ones.

  The *slice* is checked the same way. A `--line` / `--max-mutants` run narrows twice —
  emission in `render_jobs/2`, the reported sites at the end of `from_files/4` — so
  `from_files/4` compares the finished site ids against the ids it selected for emission
  and raises on any difference: a reported site whose mutant never reached the metamutant
  would run the suite unmutated and be scored a survivor.

  Both passes preserve exact `:start_id` threading (the prefix sum reproduces the
  old sequential thread) and the *let-it-crash* contract: a worker classifies an
  unparseable source as a skipped file but re-raises any other exception, with its
  original type and stacktrace, in the parent — so a tool bug still surfaces
  faithfully across the process hop, not as an opaque `Task` exit.

  Each sited file's `:start_id` is recorded under `:start_ids` — the origin of the
  file's id range *before* `:only_lines`/`:max_mutants` narrow `:sites`. A
  report-time re-render (`render_opts/3`) reads it from there, never from the
  visible sites: under `--line` the smallest surviving id is not the file's first
  mutant, and a re-render started from it would hand every id another site's code.

  We store each file's rendered metamutant source (under `:metamutants`) but not
  a precomputed `Mutare.Manifest`: the manifest (generated line ranges, for
  mapping a compile error back to a mutant) is read *only* on a failed compile,
  so `Mutare.Poison` builds it lazily from the metamutant for the offending
  file(s). Building it eagerly here was the scan's dominant cost — a full
  `Sourceror.parse_string!` of a ~40k-line metamutant takes *minutes* — and was
  thrown away on every healthy run.
  """

  alias Mutare.{Ignore, Lifting, Options, Site}
  alias Mutare.Ignore.Directive
  alias Mutare.Run.Context

  @typedoc """
  A module-level `use` the scan could not expand in-process, with the root-relative file it
  sits in (`Mutare.Transform.Uses.degraded_use/0` plus `:file`). `mix mutare --check` prints
  these: a `:call_routes` `:raw` keyed on what such a `use` injects would silently never fire.
  """
  @type degraded_use :: %{
          file: String.t(),
          module: module(),
          line: pos_integer() | nil,
          reason: atom()
        }

  @type t :: %__MODULE__{
          files: [String.t()],
          sites: [Site.t()],
          metamutants: %{optional(String.t()) => String.t()},
          sources: %{optional(String.t()) => String.t()},
          start_ids: %{optional(String.t()) => pos_integer()},
          skipped: [{String.t(), term()}],
          ineffective_ignores: [{String.t(), Directive.t(), pos_integer() | nil}],
          unknown_directives: [{String.t(), pos_integer(), String.t()}],
          ineffective_skip_lifting: [Lifting.skip_entry()],
          ineffective_call_routes: [Mutare.CallRouting.Spec.t()],
          ineffective_argument_marks: [Mutare.Mutator.mark_declaration()],
          degraded_uses: [degraded_use()]
        }

  defstruct files: [],
            sites: [],
            metamutants: %{},
            sources: %{},
            start_ids: %{},
            skipped: [],
            ineffective_ignores: [],
            unknown_directives: [],
            ineffective_skip_lifting: [],
            ineffective_call_routes: [],
            ineffective_argument_marks: [],
            degraded_uses: []

  @doc """
  Build a schema by discovering files under `root`.

  `opts` may be a `Mutare.Run.Context`, a `Mutare.Options` struct, or a keyword
  list. Discovery uses:

    * `:paths` — directories to scan recursively, or individual `.ex` files.
    * `:exclude` — wildcard patterns to drop.
    * `:only_files` — an explicit root-relative file set, such as `--since`.
    * `:only_lines` — `file:line` filters, such as `--line`; discovery is
      narrowed to the named files, then `from_files/4` filters the sites.
    * `:mutators` — forwarded to `Mutare.Transform`.
    * `:max_mutants` — caps the final schema to the first N sites; see
      `from_files/4`.
  """
  @spec build(Path.t(), Context.t() | Options.t() | keyword()) :: t()
  def build(root, opts \\ []) do
    context = Context.new(opts)
    options = context.options

    root
    |> discover(scoped_paths(context.project, options.paths), options.exclude)
    |> restrict(root, options.only_files)
    |> restrict_to_line_files(root, options.only_lines)
    |> from_files(root, context)
  end

  # In an umbrella the source roots live under each mutated app
  # (`apps/foo/lib`), so prefix every `:paths` entry with each scope app's dir.
  # No project, or a single-app project (`dir: "."`), leaves `:paths` untouched —
  # so the non-umbrella pipeline is byte-for-byte unchanged.
  defp scoped_paths(nil, paths), do: paths

  defp scoped_paths(%{mutate_scope: scope}, paths) do
    for %{dir: dir} <- scope, base <- paths, uniq: true, do: join_scope(dir, base)
  end

  # mutare:ignore[string, clause_drop] equivalent — join_scope only feeds discover's Path.wildcard/relative_to, which normalize the "./" that Path.join(".", base) adds, so "./" <> base and base discover identical files under identical relative paths
  defp join_scope(".", base), do: base
  defp join_scope(dir, base), do: Path.join(dir, base)

  # Intersect discovered files with an explicit set of root-relative paths
  # (e.g. `mix mutare --since master` → files a branch changed).
  defp restrict(files, _root, nil), do: files
  defp restrict(files, root, only), do: Enum.filter(files, &(relative(&1, root) in only))

  # When `--line FILE:LINE` scopes the run to specific `file:line` sites, only those
  # files need transforming — narrowing discovery to them keeps the metamutant small
  # and the one compile fast (the same "compile only what we run" the `--only <file>`
  # form gives). `nil` (no `--line`) leaves the file set untouched. The per-line site
  # filter still happens later, in `from_files/4`; this only prunes whole files.
  defp restrict_to_line_files(files, _root, nil), do: files

  defp restrict_to_line_files(files, root, only_lines) do
    line_files = MapSet.new(only_lines, fn {file, _line} -> file end)
    Enum.filter(files, &(relative(&1, root) in line_files))
  end

  @doc """
  Build a schema from an explicit list of files (paths recorded relative to `root`).

  Duplicate file entries are collapsed by root-relative path so each source file
  owns one stable id range.

  `skip_ids` is poison-recovery state: ids to leave out of the emitted
  metamutant while still advancing the id counter. It is passed separately from
  `Options` because it is run state, not user configuration.

  `:only_lines` filters the finished sites to the requested `file:line` pairs.
  `:max_mutants` then caps those sites in source order. Both filters are applied
  here so poison recovery can rebuild from the same inputs and still return the
  same visible slice. Every candidate reserves its id, including skipped ids,
  but only selected candidates that are neither ignored nor poisoned emit code. Poisoned and ignored
  sites still occupy their places inside the cap, as they do in the report.
  Files with no emitted mutants retain their exact original source. Changing selection
  can therefore change the metamutant and invalidate a retained sandbox's build.
  """
  @spec from_files([Path.t()], Path.t(), Context.t() | Options.t() | keyword(), MapSet.t()) :: t()
  def from_files(files, root \\ ".", opts \\ [], skip_ids \\ MapSet.new()) do
    context = Context.new(opts)
    options = context.options

    # Dedup the input by relative path. A file passed more than once would otherwise be
    # rendered twice under different `:start_id`s but collapse to a single relative-path
    # key in `render_files/5` (only the last render kept, then reused for *every*
    # occurrence) — minting duplicate, overlapping site ids and violating the
    # globally-unique-id invariant. `build/2` already dedups via `discover`; the
    # public/`rebuild` entry must too, so each source is rendered once under one id range.
    # By *relative* path, so `lib/a.ex` and `./lib/a.ex` count as one.
    files = Enum.uniq_by(files, &relative(&1, root))

    # Record the ordered, root-relative input list so the schema can be rebuilt
    # against exactly these files (see `rebuild/4`) without re-discovering.
    rel_files = Enum.map(files, &relative(&1, root))

    # Phase 1 — count (parallel, heap-isolated per worker): read each file and count its
    # mutants without rendering, firing `:on_scan` per file with the running mutant tally
    # as results stream back in input order (the live-progress contract
    # `Mutare.Report.Live` reads — mutants are discovered here, where they're counted; the
    # render-bound phase 2 shows the spinner). A tool bug raised here (e.g. a custom
    # mutator) is re-raised faithfully.
    counted = count_files(files, root, options, Context.hook(context, :on_scan))

    # Phase 2 — render (parallel, heap-isolated per worker): prefix-sum the counts so
    # each sited file knows its `:start_id` up front, then emit + render it. A failure
    # here is a tool bug (the file already parsed in phase 1) — re-raised faithfully.
    # The render pass renders each site's diff eagerly unless the run deferred it
    # (`context.defer_site_code`) — a `mix mutare` run with reporters that only show survivors,
    # which re-derive their code at report time (`Mutare.Runner.Hydrate`). The count pass builds
    # no sites, so it is unaffected. Deferral changes no id/tree/count — only whether each
    # `Mutare.Site` carries rendered code now or `nil`.
    # Independently, build the cheap `Macro` live `summary` per site when a live reporter will
    # show the in-flight mutant (`context.summarize_sites`, set by the Mix task unless `--quiet`).
    # Unlike `render_site_code`, the live line can't defer — it shows every mutant as it runs.
    render_site_code = not context.defer_site_code
    summarize_sites = context.summarize_sites

    jobs = render_jobs(counted, options.max_mutants)
    rendered = render_files(jobs, options, skip_ids, render_site_code, summarize_sites)

    rel_files
    |> assemble(counted, rendered)
    |> finalize()
    |> detect_directive_diagnostics(counted)
    |> detect_ineffective_skip_lifting(counted, options)
    |> detect_ineffective_config(counted, options)
    |> record_degraded_uses(counted)
    |> restrict_lines(options.only_lines)
    |> limit(options.max_mutants)
    |> verify_selection!(jobs)
  end

  @doc """
  Rebuild a schema from the same file list it was built with.

  This is the poison-recovery entry point. It does not rediscover files, because
  rediscovery could lose restrictions from `from_files/4`, `:only_files`,
  `:exclude`, or `:only_lines`. Reusing the recorded file list keeps the run's
  scope and mutant ids stable while adding the new `skip_ids`.

  Pass the same options used for the original schema so mutator and extension
  configuration stays unchanged.
  """
  @spec rebuild(t(), Path.t(), Context.t() | Options.t() | keyword(), MapSet.t()) :: t()
  def rebuild(%__MODULE__{files: files}, root, opts, skip_ids) do
    # Poison recovery re-scans silently: drop any `:on_scan` hook so the live
    # reporter isn't yanked back to a scan display in the middle of a run.
    context = %{Context.new(opts) | on_scan: nil}

    files
    |> Enum.map(&Path.join(root, &1))
    |> from_files(root, context, skip_ids)
  end

  @doc "Total number of mutants in the schema."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{sites: sites}), do: length(sites)

  # --- internals -----------------------------------------------------------

  # === phase 1: count ========================================================

  # Read and count every file's mutants in parallel throwaway workers (`count_one/3`),
  # yielding `[{:counted, rel, source | nil, outcome, facts}]` in **input order** (`facts` is
  # the count pass's side channel — see `facts/1`). As each file's
  # result streams back it fires `:on_scan` with the running mutant tally — so live
  # progress flows *during* the (potentially long) count phase rather than in a burst
  # after it. The heavy short-lived ASTs each `count_string/2` builds die with their
  # worker, off the scan's long-lived heap. A tool bug captured by a worker is re-raised
  # here, faithfully.
  defp count_files(files, root, options, on_scan) do
    total = length(files)

    {counted, _progress} =
      files
      |> async_stream(&count_one(&1, root, options))
      |> Enum.map_reduce({0, 0}, fn result, {done, found} ->
        counted = reraise_if_raised(result)
        done = done + 1
        found = found + mutants_found(counted)

        # A no-op unless an `:on_scan` hook is set (cleared by `rebuild/4`, so
        # poison-recovery re-scans stay silent).
        on_scan.(%{done: done, total: total, found: found})
        {counted, {done, found}}
      end)

    counted
  end

  # Count one file. An *unparseable source* is the only outcome degraded to a skipped
  # file (`{:error, _}`): the three exceptions below are the ones Elixir's parser raises
  # on malformed input, and there is nothing the tool can do about a file it cannot read
  # as Elixir. Every *other* exception means the source parsed and we then failed while
  # analyzing — a bug in this tool (a bad clause, a misbehaving custom mutator) — so it is
  # captured with its stacktrace and re-raised in the parent (`reraise_if_raised/1`); the
  # mutators run during the count, so a `RaisingMutator` surfaces here, not at render.
  # Swallowing such failures as "skipped files" is exactly how the two compile-poisoning
  # bugs hid (see NOTES.md); let them crash so they surface.
  defp count_one(file, root, %Options{} = options) do
    rel = relative(file, root)

    try do
      source = File.read!(file)
      report = Mutare.Transform.count_report(source, count_opts(options, rel))

      case report.mutants do
        0 -> {:counted, rel, source, :no_sites, facts(report)}
        n -> {:counted, rel, source, {:sites, n}, facts(report)}
      end
    rescue
      error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
        {:counted, rel, nil, {:error, error}, facts(nil)}

      other ->
        {:raise, other, __STACKTRACE__}
    catch
      kind, reason ->
        {:exit, kind, reason, __STACKTRACE__}
    end
  end

  # Count opts forward the same transform config as a render (`transform_opts/1`) so the
  # two passes count identically; `:start_id`/`:skip_ids` are omitted because the count is
  # independent of both (a skipped id still advances the counter).
  defp count_opts(%Options{} = options, rel) do
    lines =
      if options.only_lines do
        for {^rel, line} <- options.only_lines, into: MapSet.new(), do: line
      end

    # mutare:ignore[operand_swap] equivalent — disjoint keyword keys read by key, so order is irrelevant
    transform_opts(options) ++ [file: rel, selection_lines: lines]
  end

  # The count pass's side channel, one map per file (the 5th element of a `:counted` tuple) —
  # every fact the end-of-build diagnostics read, collected by the worker that parsed the file
  # so nothing below re-parses: what the file's `:skip_lifting` entries, call routes, and mark
  # declarations reached; the local ids a line selection matched; the comment-directive
  # container (directives, unknown verbs, the misplacement hint's expression end lines); and
  # the module-level `use`s the scan couldn't expand. An unparseable file contributes nothing
  # to any of them.
  defp facts(nil),
    do: %{
      skip_lifting: MapSet.new(),
      routes: MapSet.new(),
      marks: MapSet.new(),
      selected_ids: nil,
      directives: %Ignore.Directives{},
      degraded_uses: []
    }

  defp facts(report),
    do: %{
      skip_lifting: report.skip_lifting_matches,
      routes: report.route_matches,
      marks: report.mark_matches,
      selected_ids: report.selected_ids,
      directives: report.directives,
      degraded_uses: report.degraded_uses
    }

  # The mutant count an outcome contributes to the running `:on_scan` tally (0 for a
  # no-site or skipped file), summed per file as `count_files/4` consumes the stream.
  defp mutants_found({:counted, _rel, _src, {:sites, n}, _facts}), do: n
  defp mutants_found({:counted, _rel, _src, _outcome, _facts}), do: 0

  # === phase 2: render =======================================================

  # Prefix-sum the phase-1 counts into one render job per **sited** file —
  # `{rel, source, start_id, count, emit_ids}` — handing each file the globally-unique
  # `:start_id` it would have received under sequential threading (`next_id` starts at
  # 1 and advances by each file's count, in input order). No-site / skipped files
  # contribute no job (and no ids).
  defp render_jobs(counted, max_mutants) do
    {jobs, _state} =
      Enum.flat_map_reduce(counted, {1, max_mutants}, fn
        {:counted, rel, source, {:sites, count}, facts}, {next_id, remaining} ->
          {emit_ids, remaining} = select_ids(facts.selected_ids, count, next_id, remaining)
          {[{rel, source, next_id, count, emit_ids}], {next_id + count, remaining}}

        {:counted, _rel, _source, _outcome, _facts}, state ->
          {[], state}
      end)

    jobs
  end

  # Counts reserve the full file range. Selection consumes the cap in exactly the
  # same order as restrict_lines/2 then limit/2, including ignored and poisoned
  # sites; recovery must not replace a selected poisoned site with an unselected one.
  defp select_ids(nil, _count, _start_id, nil), do: {nil, nil}

  defp select_ids(local_ids, count, start_id, remaining) do
    local_ids = local_ids || 1..count//1
    selected = if is_nil(remaining), do: local_ids, else: Enum.take(local_ids, remaining)
    emit_ids = MapSet.new(selected, &(&1 + start_id - 1))
    remaining = if remaining, do: remaining - MapSet.size(emit_ids), else: nil
    {emit_ids, remaining}
  end

  # Emit + render every sited file in parallel throwaway workers (`render_one/8`),
  # returning `%{rel => {start_id, metamutant, sites}}` — the `start_id` rides along so
  # `assemble/3` can record it under `:start_ids`. The dominant `Sourceror.to_string` heap
  # dies with each worker. A tool bug captured by a worker is re-raised here.
  defp render_files(jobs, options, skip_ids, render_site_code, summarize_sites) do
    jobs
    |> async_stream(fn {rel, source, start_id, count, emit_ids} ->
      render_one(
        rel,
        source,
        start_id,
        {count, emit_ids},
        options,
        skip_ids,
        render_site_code,
        summarize_sites
      )
    end)
    |> Enum.map(&reraise_if_raised/1)
    |> Map.new(fn {:rendered, rel, start_id, meta, sites} -> {rel, {start_id, meta, sites}} end)
  end

  # Render one file at its assigned `:start_id`. The file already parsed in phase 1, so any
  # exception here is a tool bug (a bad clause, a Sourceror formatter crash) — captured and
  # re-raised faithfully, never swallowed. `verify_count!/3` guards the load-bearing id
  # invariant: the rendered `next_id - start_id` must equal phase 1's count, or files would
  # silently overlap ids (the two passes are the same deterministic pipeline, so they agree).
  defp render_one(
         rel,
         source,
         start_id,
         {count, emit_ids},
         %Options{} = options,
         skip_ids,
         render_site_code,
         summarize_sites
       ) do
    opts =
      transform_opts(options) ++
        [
          file: rel,
          start_id: start_id,
          runtime_namespace: rel,
          skip_ids: skip_ids,
          emit_ids: emit_ids,
          render_site_code: render_site_code,
          summarize_sites: summarize_sites,
          # The count pass already ran this source through the same pipeline and printed any
          # advisory warnings (there, so a zero-site file — counted but never rendered — still
          # warns); re-printing them here would double every warning for sited files.
          warnings: false
        ]

    try do
      {meta, sites, next_id} = Mutare.Transform.transform_string_with_sites(source, opts)
      verify_count!(rel, next_id - start_id, count)
      {:rendered, rel, start_id, meta, sites}
    rescue
      other -> {:raise, other, __STACKTRACE__}
    catch
      kind, reason -> {:exit, kind, reason, __STACKTRACE__}
    end
  end

  defp verify_count!(_rel, count, count), do: :ok

  defp verify_count!(rel, rendered, counted) do
    raise "Mutare.Schema: mutant-count drift for #{rel} — counted #{counted}, rendered #{rendered}. " <>
            "The two-phase build runs the same analyze→plan→emit pipeline twice (count, then " <>
            "render), so the counts agree only if that pipeline is deterministic for one source — " <>
            "a nondeterministic custom mutator or `Mutare.UseExpansion.expand_use/3` (both run in each " <>
            "pass) is the usual cause. Cross-file id stability depends on the counts matching."
  end

  # `verify_count!/3` for the *slice*: the sites the report will show must be exactly the ids
  # `render_jobs/2` handed the renderer to emit. Both narrow the same `--line`/`--max-mutants`
  # selection, from different material — emission from the count pass's matching local ids and a
  # running cap remainder, the report from `restrict_lines/2` + `limit/2` over the finished sites —
  # and they land on the same slice only because files and ids reach both in one order. No
  # structure enforces that order, so a plausible tidy-up (sorting `:sites`, reordering
  # `assemble/3`, moving a filter) slides the two apart silently, and a reported site whose mutant
  # never reached the metamutant runs the suite unmutated: every one of them scores as a
  # *survivor*. Compare the sets rather than trust the order — NOTES "The reported slice and the
  # emitted slice are checked against each other".
  defp verify_selection!(%__MODULE__{sites: sites} = schema, jobs) do
    reported = MapSet.new(sites, & &1.id)
    selected = Enum.reduce(jobs, MapSet.new(), &MapSet.union(&2, job_ids(&1)))
    unemitted = MapSet.difference(reported, selected)
    unreported = MapSet.difference(selected, reported)

    if MapSet.size(unemitted) == 0 and MapSet.size(unreported) == 0 do
      schema
    else
      raise "Mutare.Schema: selection drift — the reported sites and the emitted mutants " <>
              "disagree. " <>
              unemitted_clause(sites, unemitted) <>
              unreported_clause(unreported) <>
              "`render_jobs/2` picks the ids the metamutant emits and `restrict_lines/2` + " <>
              "`limit/2` pick the sites the report shows; the two derive one slice separately and " <>
              "agree only while sites stay in file/id order. A reported site with no emitted " <>
              "mutant runs the suite unmutated and is scored a survivor."
    end
  end

  # A render job's selected ids: the explicit `emit_ids`, or — for a file no line filter or cap
  # narrowed — its whole reserved range.
  defp job_ids({_rel, _source, start_id, count, nil}),
    do: MapSet.new(start_id..(start_id + count - 1)//1)

  defp job_ids({_rel, _source, _start_id, _count, emit_ids}), do: emit_ids

  # The two directions read differently, so name each: a reported id nothing emitted is the false
  # survivor; an emitted id nothing reports is a mutant the run compiled but will never test.
  defp unemitted_clause(sites, ids) do
    case MapSet.size(ids) do
      0 ->
        ""

      size ->
        located =
          sites
          |> Enum.filter(&MapSet.member?(ids, &1.id))
          |> Enum.take(3)
          |> Enum.map_join(", ", &"#{&1.id} at #{&1.file}:#{&1.line}")

        "#{size} reported site(s) have no emitted mutant (#{located}). "
    end
  end

  defp unreported_clause(ids) do
    case MapSet.size(ids) do
      0 ->
        ""

      size ->
        listed = ids |> Enum.sort() |> Enum.take(3) |> Enum.join(", ")
        "#{size} emitted id(s) reach no reported site (#{listed}). "
    end
  end

  # === assembly ==============================================================

  # Fold the phase-1 outcomes (in input order) into the schema, slotting each sited file's
  # rendered metamutant + sites + `:start_id` (from `rendered`), keeping a site-less but
  # parsed file as sources-only, and recording an unparseable file under `:skipped`. Sites accumulate
  # reversed (O(1) prepend per file); `finalize/1` flips them back to order once. We store
  # the rendered metamutant but no precomputed manifest — that's read only on a failed
  # compile, so `Mutare.Poison` re-derives it lazily (see `Mutare.Poison.ids/2`).
  defp assemble(rel_files, counted, rendered) do
    Enum.reduce(counted, %__MODULE__{files: rel_files}, fn
      {:counted, rel, source, {:sites, _count}, _facts}, schema ->
        {start_id, meta, sites} = Map.fetch!(rendered, rel)

        %{
          schema
          | sites: Enum.reverse(sites, schema.sites),
            metamutants: Map.put(schema.metamutants, rel, meta),
            sources: Map.put(schema.sources, rel, source),
            start_ids: Map.put(schema.start_ids, rel, start_id)
        }

      {:counted, rel, source, :no_sites, _facts}, schema ->
        # mutare:ignore[map_keyword] equivalent — dedup'd input → each rel put once (see above)
        %{schema | sources: Map.put(schema.sources, rel, source)}

      {:counted, rel, _source, {:error, reason}, _facts}, schema ->
        %{schema | skipped: [{rel, reason} | schema.skipped]}
    end)
  end

  # === shared worker plumbing ================================================

  # Run `fun` over `enum` in parallel throwaway workers, **ordered** (so callers see input
  # order for id threading, scan progress, and site assembly) and untimed (a big file can
  # take seconds). Returns a **lazy** stream the caller forces — `count_files/4` via
  # `Enum.map_reduce` (so it can fire `:on_scan` per file *as results arrive*, not in one
  # end-of-phase burst), `render_files/5` via `Enum.map`. Each worker classifies its own
  # outcome — a result tuple or a captured `{:raise, error, stacktrace}` — so it never
  # crashes the stream; `reraise_if_raised/1` surfaces a captured tool bug in the parent,
  # with its original type and trace, rather than as an opaque `Task` exit. A worker that
  # *exits* (a `throw`/`exit`, not an exception) re-exits the parent with the same reason,
  # matching `Task.await`'s behaviour.
  defp async_stream(enum, fun) do
    enum
    |> Task.async_stream(fun,
      ordered: true,
      max_concurrency: scan_concurrency(),
      timeout: :infinity
    )
    |> Stream.map(fn
      {:ok, result} -> result
      {:exit, reason} -> exit(reason)
    end)
  end

  defp reraise_if_raised({:raise, error, stacktrace}), do: reraise(error, stacktrace)

  defp reraise_if_raised({:exit, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp reraise_if_raised(result), do: result

  # The scan is CPU-bound (parse + analyze + render), so size both passes to the
  # schedulers — independent of the runner's `:workers`, which bounds the per-mutant
  # `mix test` OS processes (a different resource).
  defp scan_concurrency, do: System.schedulers_online()

  # Forward `:mutators` (when set), `:call_routes`, `:skip_lifting`, and `:extensions` to
  # the transform. A `nil` `:mutators` lets `Mutare.Transform` use its default set (we never hard-code that default
  # here); when set it carries the resolved `Mutare.Mutator.Spec`s — including any
  # `{module, opts}` config (e.g. a mutator's `call_option_keys: false`). `:call_routes` carries the
  # resolved `Mutare.CallRouting.Spec`s (known-macro argument routing), `[]` when none; `:extensions`
  # carries non-mutating modules implementing `Mutare.CallRouting`, `Mutare.UseExpansion`, or both;
  # the transform merges those capabilities with built-ins and enabled mutator capabilities.
  # `:expand_uses` carries the `use`-expansion toggle (default `true`).
  defp transform_opts(%Options{
         mutators: mutators,
         call_routes: macros,
         argument_marks: argument_marks,
         skip_lifting: skip_lifting,
         extensions: extensions,
         expand_uses: expand_uses
       }) do
    mutator_opts = if mutators == nil, do: [], else: [mutators: mutators]

    # `macro_opts`'s `if false` mutant is equivalent (`[call_routes: []]` behaves as no `:call_routes`), but
    # `if true` is a real kill (macros then never reach the transform) on the same [conditional]
    # family/line — so it is deliberately *not* ignored (a line filter would hide the kill).
    macro_opts = if macros == [], do: [], else: [call_routes: macros]
    extension_opts = if extensions == [], do: [], else: [extensions: extensions]

    # mutare:ignore[operand_swap] equivalent — disjoint keyword keys read by key, so order is irrelevant
    mutator_opts ++
      macro_opts ++
      extension_opts ++
      [argument_marks: argument_marks, skip_lifting: skip_lifting, expand_uses: expand_uses]
  end

  @doc """
  Transform options for re-rendering one file's sites.

  The returned keyword list is `transform_opts/1` plus `:file`, `:start_id`, and
  the file's `:runtime_namespace`.
  `Mutare.Runner.Hydrate` uses it when a scan deferred site-code rendering and a
  report later needs the original/mutated code for one displayed site.

  The `:start_id` must be the schema's recorded `:start_ids` entry for `file` —
  the pre-filter origin of its id range — so the re-rendered sites line up with
  the original scan even when `:only_lines`/`:max_mutants` narrowed `:sites`. `:skip_ids` and
  `:render_site_code` are intentionally left to `Mutare.Transform.render_sites/2`;
  neither changes the id-to-code mapping.
  """
  @spec render_opts(Options.t(), String.t(), pos_integer()) :: keyword()
  def render_opts(%Options{} = options, file, start_id) do
    transform_opts(options) ++ [file: file, start_id: start_id, runtime_namespace: file]
  end

  defp finalize(%__MODULE__{} = schema) do
    # `skipped: Enum.sort` is equivalent here (a unique path key sorts to the same order as the
    # reverse), but `sites: Enum.sort` is a real (block-macro-only) kill on the same
    # [collection_arity] family/line — so neither is ignored (a line filter would hide the kill).
    %{schema | sites: Enum.reverse(schema.sites), skipped: Enum.reverse(schema.skipped)}
  end

  # Record the scan-time directive diagnostics, so the Mix task can warn — and
  # `--strict-ignores` can fail — on a comment that silently did nothing:
  #
  #   * every `# mutare:ignore` directive that suppressed no mutant
  #     (`Mutare.Ignore.ineffective/2` — a typo'd / misplaced / family-less
  #     directive), each with a misplacement hint (`Ignore.misplacement_hint/3`,
  #     or `nil`): the line inside the same multi-line expression that has the
  #     mutants the directive named — the "directive on the pipe's first line" miss;
  #   * every comment claiming the reserved `mutare:` namespace with no recognized
  #     directive (the container's `unknown` — a typo'd or future verb).
  #
  # Run after `finalize/1` (sites in order) but *before* `restrict_lines`/`limit`,
  # so detection sees the full mutation set: a `--line`/`--max-mutants` trim must
  # not make a real directive look ineffective.
  #
  # Pure over the count pass's facts: each file's directive container — its directives,
  # unknown verbs, and the expression end lines the hint is bounded by — was harvested by
  # the worker that parsed the file (`Mutare.Ignore.directives_from_ast/1`), so nothing here
  # touches a source or an AST. A file with nothing to diagnose (the common case, and every
  # unparseable file) carries an empty container and is skipped outright.
  defp detect_directive_diagnostics(%__MODULE__{sites: sites} = schema, counted) do
    sites_by_file = Enum.group_by(sites, & &1.file)

    diagnostics =
      for {:counted, file, _src, _outcome, %{directives: directives}} <- counted,
          not Ignore.Directives.empty?(directives),
          do: {file, file_diagnostics(directives, Map.get(sites_by_file, file, []))}

    ineffective =
      for {file, {ineffective, _unknown}} <- diagnostics,
          {directive, hint} <- ineffective,
          do: {file, directive, hint}

    unknown =
      for {file, {_ineffective, unknown}} <- diagnostics,
          {line, head} <- unknown,
          do: {file, line, head}

    %{
      schema
      | ineffective_ignores: Enum.sort_by(ineffective, fn {f, d, _h} -> {f, d.line} end),
        unknown_directives: Enum.sort_by(unknown, fn {f, l, _h} -> {f, l} end)
    }
  end

  # One container serves both diagnostics: `{ineffective_with_hints, unknown_verbs}`.
  defp file_diagnostics(%Ignore.Directives{} = directives, sites) do
    occupied = Enum.map(sites, &{&1.line, &1.mutator, &1.variant})

    ineffective =
      directives
      |> Ignore.ineffective(occupied)
      |> Enum.map(&{&1, Ignore.misplacement_hint(directives, &1, occupied)})

    {ineffective, directives.unknown}
  end

  # The `:skip_lifting` mirror of the ineffective-ignore diagnostic: record every configured
  # entry that matched no function anywhere in the scan, so the Mix task can warn — otherwise
  # a typo'd module or a wrong arity (`def parse(input, opts \\ [])` is arity 2 — the *written*
  # head, not a caller's) leaves the escape hatch silently inert. Matches are unioned from the
  # count pass, which sees every scanned file (a zero-site file included; an unparseable file
  # contributes nothing, but it also yields no metamutant, so an entry aimed at it really is
  # without effect).
  #
  # Only a *full* scan can prove an entry ineffective: `--since`/`--only`/`--line` narrow the
  # file set, so absence there proves nothing and the diagnostic is suppressed. A poison
  # rebuild re-records the same (deterministic) result; the Mix task warns once, after the
  # initial build.
  defp detect_ineffective_skip_lifting(schema, counted, %Options{} = options) do
    configured = options.skip_lifting

    if MapSet.size(configured) == 0 or options.only_files != nil or options.only_lines != nil do
      schema
    else
      matched = union_matches(counted, :skip_lifting)

      ineffective =
        configured |> MapSet.difference(matched) |> Enum.sort_by(&Lifting.format_entry/1)

      %{schema | ineffective_skip_lifting: ineffective}
    end
  end

  # The same diagnostic for the two configuration facilities: a declarative `call_routes:` entry
  # whose key (`Mutare.CallRouting.Spec.key/1`, wildcards included — a concrete call reaching a
  # wildcard route through the lookup cascade counts as that route's match) no resolved call hit,
  # and an `argument_marks:` entry whose `{module, function, arity}` no resolved call carried a mark
  # for. Both are read off the resolver's stamps by `Mutare.Transform.ConfigMatches` in the count
  # pass, and both are gated on a full scan exactly like `:skip_lifting` above.
  defp detect_ineffective_config(schema, counted, %Options{} = options) do
    if (options.call_routes == [] and options.argument_marks == []) or options.only_files != nil or
         options.only_lines != nil do
      schema
    else
      matched_routes = union_matches(counted, :routes)
      matched_marks = union_matches(counted, :marks)

      routes =
        Enum.reject(
          options.call_routes,
          &MapSet.member?(matched_routes, Mutare.CallRouting.Spec.key(&1))
        )

      marks =
        Enum.reject(options.argument_marks, fn {module, fun, arity, _positions, _label} ->
          MapSet.member?(
            matched_marks,
            {Mutare.Transform.Aliases.from_module(module), fun, arity}
          )
        end)

      %{schema | ineffective_call_routes: routes, ineffective_argument_marks: marks}
    end
  end

  defp union_matches(counted, kind) do
    Enum.reduce(counted, MapSet.new(), fn {:counted, _rel, _src, _outcome, facts}, acc ->
      MapSet.union(acc, Map.fetch!(facts, kind))
    end)
  end

  # The module-level `use`s the scan couldn't expand in-process, across every counted file —
  # read by the count pass off the tree it annotated (`Mutare.Transform.Uses.degraded_uses/1`),
  # each stamped with its file here. `mix mutare --check` prints them; a normal run carries
  # the (normally empty) list for the cost of one prewalk per file. Empty under
  # `expand_uses: false`: nothing was expanded, so nothing degraded.
  defp record_degraded_uses(%__MODULE__{} = schema, counted) do
    degraded =
      for {:counted, rel, _src, _outcome, facts} <- counted,
          entry <- facts.degraded_uses,
          do: Map.put(entry, :file, rel)

    %{schema | degraded_uses: degraded}
  end

  # Cap the schema to at most `max` mutants (`--max-mutants`), keeping the first
  # `max` sites in source order. `nil` means no cap. Applied after `finalize/1`
  # (so the sites are already in order) and inside every `from_files/4` (so a
  # poison rebuild stays capped). render_jobs/2 applies this same selection to
  # emission; the full site list survives until here for directive diagnostics.
  defp limit(%__MODULE__{} = schema, nil), do: schema

  # mutare:ignore[relational, conditional, logical] equivalent — Options validates :max_mutants as a positive integer or nil, so this defensive guard (limit/2 is private) never sees the values that would distinguish these
  defp limit(%__MODULE__{sites: sites} = schema, max) when is_integer(max) and max > 0,
    do: %{schema | sites: Enum.take(sites, max)}

  # Keep only the sites on an explicitly named `file:line` (`--line`). `nil` keeps
  # every site. Applied here — inside *every* `from_files/4` — so a poison rebuild
  # reapplies it, exactly like `limit/2` (`--max-mutants`). The count pass records
  # matching local ids so emission applies the same selection before rendering.
  # A site's `{file, line}`
  # is its recorded original location (`file:line` as the report prints it), so a
  # filter copied from a survivor header matches.
  defp restrict_lines(%__MODULE__{} = schema, nil), do: schema

  defp restrict_lines(%__MODULE__{sites: sites} = schema, only_lines),
    do: %{schema | sites: Enum.filter(sites, &MapSet.member?(only_lines, {&1.file, &1.line}))}

  defp discover(root, paths, exclude) do
    excluded = Enum.flat_map(exclude, &Path.wildcard(Path.join(root, &1)))

    paths
    |> Enum.flat_map(&expand(root, &1))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in excluded))
    |> Enum.sort()
  end

  # A `:paths` entry (`--only`) is either a directory to scan recursively for
  # `.ex` sources or a single `.ex` file (a glob in either position is honoured
  # by `Path.wildcard`). The check is purely on the `.ex` extension, so it is
  # additive: a directory entry globs `**/*.ex` exactly as before, while a `.ex`
  # entry — which previously expanded to `<file>/**/*.ex` and matched nothing —
  # is now taken verbatim. A non-existent entry yields nothing either way.
  defp expand(root, path) do
    if Path.extname(path) == ".ex" do
      Path.wildcard(Path.join(root, path))
    else
      Path.wildcard(Path.join([root, path, "**", "*.ex"]))
    end
  end

  defp relative(file, root) do
    file |> Path.relative_to(root) |> to_string()
  end
end
