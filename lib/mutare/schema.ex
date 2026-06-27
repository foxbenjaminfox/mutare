defmodule Mutare.Schema do
  @moduledoc """
  The mutant schema for a whole project: every in-scope source transformed into
  its metamutant, with globally-unique mutant ids threaded across files.

  This is what the runner compiles once and the report reads from.
  Files that have no mutation sites, or that *fail to parse*, are left out of
  `:metamutants` (their originals are used as-is) but never crash the build — a
  single unparseable file should not sink the run. A failure *after* a clean
  parse (transform or render) is a bug in this tool, not bad input, and is left
  to crash: see `render_one/5`.

  ## Two-phase build (`from_files/4`)

  Mutant ids are baked into each metamutant's selector clauses, so a naive
  per-file render can't run concurrently — file *i*'s `:start_id` is file
  *i-1*'s `next_id`. The build decouples id assignment from rendering in two
  passes, both run in **throwaway worker processes** so each file's heavy,
  short-lived ASTs (the emitted tree, Sourceror's render buffers) die with their
  worker instead of accumulating in the scan's long-lived heap, where they made
  every GC scan the growing live set and inflated a big file's transform
  several-fold (see NOTES "Scan is transform-bound"):

    1. **Count** (`count_files/3`) — `Mutare.Transform.count_string/2` per file,
       in parallel. It runs the same analyze → plan → emit pipeline but skips the
       dominant final render, returning just each file's mutant count. The count
       is drift-proof: it comes from the *same* id-claiming path emission uses, so
       it equals the matching render's `next_id - start_id` by construction.
    2. **Render** (`render_files/3`) — prefix-sum the counts so each sited file
       knows its globally-unique `:start_id` up front, then
       `Mutare.Transform.transform_string/2` each file (with that `:start_id` and
       the run's `:skip_ids`) in parallel. `render_one/5` re-checks the count
       against the rendered `next_id` and fails loudly on any drift, since id
       stability across files depends on the two passes agreeing.

  The two passes agree only because the pipeline they share — parse, `use`-expansion,
  resolution, and every mutator — is a *deterministic* function of the source and opts;
  it runs once per pass, so a nondeterministic custom mutator or plugin `expand_use/3`
  surfaces as that `render_one/5` drift crash rather than a silent id overlap.
  `from_files/4` also dedups its input by relative path, so a file passed twice is
  rendered once, under one id range — never two overlapping ones.

  Both passes preserve exact `:start_id` threading (the prefix sum reproduces the
  old sequential thread) and the *let-it-crash* contract: a worker classifies an
  unparseable source as a skipped file but re-raises any other exception, with its
  original type and stacktrace, in the parent — so a tool bug still surfaces
  faithfully across the process hop, not as an opaque `Task` exit.

  We store each file's rendered metamutant source (under `:metamutants`) but not
  a precomputed `Mutare.Manifest`: the manifest (generated line ranges, for
  mapping a compile error back to a mutant) is read *only* on a failed compile,
  so `Mutare.Poison` builds it lazily from the metamutant for the offending
  file(s). Building it eagerly here was the scan's dominant cost — a full
  `Sourceror.parse_string!` of a ~40k-line metamutant takes *minutes* — and was
  thrown away on every healthy run.
  """

  alias Mutare.{Ignore, Options, Site}
  alias Mutare.Ignore.Directive

  @type t :: %__MODULE__{
          files: [String.t()],
          sites: [Site.t()],
          metamutants: %{optional(String.t()) => String.t()},
          sources: %{optional(String.t()) => String.t()},
          skipped: [{String.t(), term()}],
          ineffective_ignores: [{String.t(), Directive.t()}]
        }

  defstruct files: [],
            sites: [],
            metamutants: %{},
            sources: %{},
            skipped: [],
            ineffective_ignores: []

  @doc """
  Build a schema by discovering files under `root`.

  `opts` is a `Mutare.Options` (or a keyword list resolved into one). It reads
  `:paths` (directories to scan recursively, or individual `.ex` files),
  `:exclude` (wildcard patterns dropped),
  `:only_files` (restrict to an explicit set, e.g. `--since`), `:only_lines`
  (restrict the run to specific `file:line` sites — `--line` — also narrowing the
  scanned files to those named; see `from_files/4`), `:mutators` (passed through
  to `Mutare.Transform`), and `:max_mutants` (cap the schema to the first N
  mutants; see `from_files/4`).
  """
  @spec build(Path.t(), Options.t() | keyword()) :: t()
  def build(root, opts \\ []) do
    options = Options.new(opts)

    root
    |> discover(scoped_paths(options), options.exclude)
    |> restrict(root, options.only_files)
    |> restrict_to_line_files(root, options.only_lines)
    |> from_files(root, options)
  end

  # In an umbrella the source roots live under each mutated app
  # (`apps/foo/lib`), so prefix every `:paths` entry with each scope app's dir.
  # No project, or a single-app project (`dir: "."`), leaves `:paths` untouched —
  # so the non-umbrella pipeline is byte-for-byte unchanged.
  defp scoped_paths(%Options{project: nil, paths: paths}), do: paths

  defp scoped_paths(%Options{project: %{mutate_scope: scope}, paths: paths}) do
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

  `skip_ids` is poison-recovery state (mutant ids to drop), threaded separately
  from the user `Options` because it is internal transform plumbing, not config.

  Honors `:only_lines` (`--line`) and `:max_mutants` (`--max-mutants`): the
  finished schema's sites are filtered to the named `file:line`s, then capped to
  the first N (in source order). Both are applied here — inside *every*
  `from_files/4` — so they survive a poison rebuild (which regenerates the sites
  from scratch); the per-file metamutant sources still embed every mutant, so
  poison recovery is unaffected and a poisoned site within the first N is simply
  backfilled by the next one on rebuild.
  """
  @spec from_files([Path.t()], Path.t(), Options.t() | keyword(), MapSet.t()) :: t()
  def from_files(files, root \\ ".", opts \\ [], skip_ids \\ MapSet.new()) do
    options = Options.new(opts)

    # Dedup the input by relative path. A file passed more than once would otherwise be
    # rendered twice under different `:start_id`s but collapse to a single relative-path
    # key in `render_files/3` (only the last render kept, then reused for *every*
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
    counted = count_files(files, root, options)

    # Phase 2 — render (parallel, heap-isolated per worker): prefix-sum the counts so
    # each sited file knows its `:start_id` up front, then emit + render it. A failure
    # here is a tool bug (the file already parsed in phase 1) — re-raised faithfully.
    rendered = counted |> render_jobs() |> render_files(options, skip_ids)

    rel_files
    |> assemble(counted, rendered)
    |> finalize()
    |> detect_ineffective_ignores()
    |> restrict_lines(options.only_lines)
    |> limit(options.max_mutants)
  end

  @doc """
  Rebuild a schema against the *same* files it was originally built from.

  Poison recovery (`Mutare.Runner`) relies on this: re-discovering via `build/2`
  would ignore any restriction baked into the supplied schema (a custom
  `from_files/4` set, or an `:only_files`/`:exclude`-restricted `build/2`) and
  could silently expand to a different file set. Replaying the recorded file list
  preserves the restriction and keeps mutant ids stable (the transform advances
  its id counter even for `:skip_ids`).

  Pass through the original `Options` (so `:mutators` survive) and the new
  accumulated `skip_ids`.
  """
  @spec rebuild(t(), Path.t(), Options.t() | keyword(), MapSet.t()) :: t()
  def rebuild(%__MODULE__{files: files}, root, opts, skip_ids) do
    # Poison recovery re-scans silently: drop any `:on_scan` hook so the live
    # reporter isn't yanked back to a scan display in the middle of a run.
    opts = %{Options.new(opts) | on_scan: nil}

    files
    |> Enum.map(&Path.join(root, &1))
    |> from_files(root, opts, skip_ids)
  end

  @doc "Total number of mutants in the schema."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{sites: sites}), do: length(sites)

  # --- internals -----------------------------------------------------------

  # === phase 1: count ========================================================

  # Read and count every file's mutants in parallel throwaway workers (`count_one/3`),
  # yielding `[{:counted, rel, source | nil, outcome}]` in **input order**. As each file's
  # result streams back it fires `:on_scan` with the running mutant tally — so live
  # progress flows *during* the (potentially long) count phase rather than in a burst
  # after it. The heavy short-lived ASTs each `count_string/2` builds die with their
  # worker, off the scan's long-lived heap. A tool bug captured by a worker is re-raised
  # here, faithfully.
  defp count_files(files, root, options) do
    on_scan = Options.hook(options, :on_scan)
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

      case Mutare.Transform.count_string(source, count_opts(options, rel)) do
        0 -> {:counted, rel, source, :no_sites}
        n -> {:counted, rel, source, {:sites, n}}
      end
    rescue
      error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
        {:counted, rel, nil, {:error, error}}

      other ->
        {:raise, other, __STACKTRACE__}
    end
  end

  # Count opts forward the same transform config as a render (`transform_opts/1`) so the
  # two passes count identically; `:start_id`/`:skip_ids` are omitted because the count is
  # independent of both (a skipped id still advances the counter).
  # mutare:ignore[operand_swap] equivalent — disjoint keyword keys read by key, so order is irrelevant
  defp count_opts(%Options{} = options, rel), do: transform_opts(options) ++ [file: rel]

  # The mutant count an outcome contributes to the running `:on_scan` tally (0 for a
  # no-site or skipped file), summed per file as `count_files/3` consumes the stream.
  defp mutants_found({:counted, _rel, _src, {:sites, n}}), do: n
  defp mutants_found({:counted, _rel, _src, _outcome}), do: 0

  # === phase 2: render =======================================================

  # Prefix-sum the phase-1 counts into one render job per **sited** file —
  # `{rel, source, start_id, count}` — handing each file the globally-unique
  # `:start_id` it would have received under sequential threading (`next_id` starts at
  # 1 and advances by each file's count, in input order). No-site / skipped files
  # contribute no job (and no ids).
  defp render_jobs(counted) do
    {jobs, _next_id} =
      Enum.flat_map_reduce(counted, 1, fn
        {:counted, rel, source, {:sites, count}}, next_id ->
          {[{rel, source, next_id, count}], next_id + count}

        {:counted, _rel, _source, _outcome}, next_id ->
          {[], next_id}
      end)

    jobs
  end

  # Emit + render every sited file in parallel throwaway workers (`render_one/5`),
  # returning `%{rel => {metamutant, sites}}`. The dominant `Sourceror.to_string` heap
  # dies with each worker. A tool bug captured by a worker is re-raised here.
  defp render_files(jobs, options, skip_ids) do
    jobs
    |> async_stream(fn {rel, source, start_id, count} ->
      render_one(rel, source, start_id, count, options, skip_ids)
    end)
    |> Enum.map(&reraise_if_raised/1)
    |> Map.new(fn {:rendered, rel, meta, sites} -> {rel, {meta, sites}} end)
  end

  # Render one file at its assigned `:start_id`. The file already parsed in phase 1, so any
  # exception here is a tool bug (a bad clause, a Sourceror formatter crash) — captured and
  # re-raised faithfully, never swallowed. `verify_count!/3` guards the load-bearing id
  # invariant: the rendered `next_id - start_id` must equal phase 1's count, or files would
  # silently overlap ids (the two passes are the same deterministic pipeline, so they agree).
  defp render_one(rel, source, start_id, count, %Options{} = options, skip_ids) do
    # mutare:ignore[operand_swap] equivalent — disjoint keyword keys read by key, so order is irrelevant
    opts = transform_opts(options) ++ [file: rel, start_id: start_id, skip_ids: skip_ids]

    try do
      {meta, sites, next_id} = Mutare.Transform.transform_string(source, opts)
      verify_count!(rel, next_id - start_id, count)
      {:rendered, rel, meta, sites}
    rescue
      other -> {:raise, other, __STACKTRACE__}
    end
  end

  defp verify_count!(_rel, count, count), do: :ok

  defp verify_count!(rel, rendered, counted) do
    raise "Mutare.Schema: mutant-count drift for #{rel} — counted #{counted}, rendered #{rendered}. " <>
            "The two-phase build runs the same analyze→plan→emit pipeline twice (count, then " <>
            "render), so the counts agree only if that pipeline is deterministic for one source — " <>
            "a nondeterministic custom mutator or `Mutare.Plugin.expand_use/3` (both run in each " <>
            "pass) is the usual cause. Cross-file id stability depends on the counts matching."
  end

  # === assembly ==============================================================

  # Fold the phase-1 outcomes (in input order) into the schema, slotting each sited file's
  # rendered metamutant + sites (from `rendered`), keeping a site-less but parsed file as
  # sources-only, and recording an unparseable file under `:skipped`. Sites accumulate
  # reversed (O(1) prepend per file); `finalize/1` flips them back to order once. We store
  # the rendered metamutant but no precomputed manifest — that's read only on a failed
  # compile, so `Mutare.Poison` re-derives it lazily (see `Mutare.Poison.ids/2`).
  defp assemble(rel_files, counted, rendered) do
    Enum.reduce(counted, %__MODULE__{files: rel_files}, fn
      {:counted, rel, source, {:sites, _count}}, schema ->
        {meta, sites} = Map.fetch!(rendered, rel)

        %{
          schema
          | sites: Enum.reverse(sites, schema.sites),
            # mutare:ignore[map_keyword] equivalent — `from_files/4` dedups its input by relative
            # path, so each `rel` is assembled exactly once and neither key ever pre-exists; put
            # and put_new agree (here, and for `sources` in every branch).
            metamutants: Map.put(schema.metamutants, rel, meta),
            sources: Map.put(schema.sources, rel, source)
        }

      {:counted, rel, source, :no_sites}, schema ->
        # mutare:ignore[map_keyword] equivalent — dedup'd input → each rel put once (see above)
        %{schema | sources: Map.put(schema.sources, rel, source)}

      {:counted, rel, _source, {:error, reason}}, schema ->
        %{schema | skipped: [{rel, reason} | schema.skipped]}
    end)
  end

  # === shared worker plumbing ================================================

  # Run `fun` over `enum` in parallel throwaway workers, **ordered** (so callers see input
  # order for id threading, scan progress, and site assembly) and untimed (a big file can
  # take seconds). Returns a **lazy** stream the caller forces — `count_files/3` via
  # `Enum.map_reduce` (so it can fire `:on_scan` per file *as results arrive*, not in one
  # end-of-phase burst), `render_files/3` via `Enum.map`. Each worker classifies its own
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
  defp reraise_if_raised(result), do: result

  # The scan is CPU-bound (parse + analyze + render), so size both passes to the
  # schedulers — independent of the runner's `:workers`, which bounds the per-mutant
  # `mix test` OS processes (a different resource).
  defp scan_concurrency, do: System.schedulers_online()

  # Forward `:mutators` (when set), `:macros`, and `:plugins` to the transform. A `nil`
  # `:mutators` lets `Mutare.Transform` use its default set (we never hard-code that default
  # here); when set it carries the resolved `Mutare.Mutator.Spec`s — including any
  # `{module, opts}` config (e.g. a mutator's `call_option_keys: false`). `:macros` carries the
  # resolved `Mutare.Macro.Spec`s (known-macro argument routing), `[]` when none; `:plugins`
  # carries the `Mutare.Plugin` modules (their `macros/0` + `use`-expansion overrides); the
  # transform merges all of these with the built-ins and any enabled mutator's `macros/0`.
  # `:expand_uses` carries the `use`-expansion toggle (default `true`).
  defp transform_opts(%Options{
         mutators: mutators,
         macros: macros,
         plugins: plugins,
         expand_uses: expand_uses
       }) do
    mutator_opts = if mutators == nil, do: [], else: [mutators: mutators]

    # `macro_opts`'s `if false` mutant is equivalent (`[macros: []]` behaves as no `:macros`), but
    # `if true` is a real kill (macros then never reach the transform) on the same [conditional]
    # family/line — so it is deliberately *not* ignored (a line filter would hide the kill).
    macro_opts = if macros == [], do: [], else: [macros: macros]
    plugin_opts = if plugins == [], do: [], else: [plugins: plugins]

    # mutare:ignore[operand_swap] equivalent — disjoint keyword keys read by key, so order is irrelevant
    mutator_opts ++ macro_opts ++ plugin_opts ++ [expand_uses: expand_uses]
  end

  defp finalize(%__MODULE__{} = schema) do
    # `skipped: Enum.sort` is equivalent here (a unique path key sorts to the same order as the
    # reverse), but `sites: Enum.sort` is a real (block-macro-only) kill on the same
    # [collection_arity] family/line — so neither is ignored (a line filter would hide the kill).
    %{schema | sites: Enum.reverse(schema.sites), skipped: Enum.reverse(schema.skipped)}
  end

  # Record every `# mutare:ignore` directive that suppressed no mutant
  # (`Mutare.Ignore.ineffective/2`), so the Mix task can warn — and
  # `--strict-ignores` can fail — on a typo'd / misplaced / family-less directive
  # that silently did nothing. Run after `finalize/1` (sites in order) but
  # *before* `restrict_lines`/`limit`, so detection sees the full mutation set: a
  # `--line`/`--max-mutants` trim must not make a real directive look ineffective.
  #
  # Only files whose source contains the literal `mutare:ignore` are re-parsed
  # (`Ignore.directives/1`); the cheap substring prefilter keeps every other file
  # off the parse path. A `sources` entry is always a file that parsed cleanly
  # during transform (the `{:error, _}` branch of `add_file/6` records no source),
  # so the re-parse cannot raise here.
  defp detect_ineffective_ignores(%__MODULE__{sources: sources, sites: sites} = schema) do
    sites_by_file = Enum.group_by(sites, & &1.file)

    ineffective =
      for {file, source} <- sources,
          # mutare:ignore[string] equivalent — a substring prefilter; widening it only re-parses more directive-free files, and directives come from comment metadata so a string match never false-positives
          String.contains?(source, "mutare:ignore"),
          directive <- file_ineffective(source, Map.get(sites_by_file, file, [])),
          do: {file, directive}

    %{schema | ineffective_ignores: Enum.sort_by(ineffective, fn {f, d} -> {f, d.line} end)}
  end

  defp file_ineffective(source, sites) do
    occupied = Enum.map(sites, &{&1.line, &1.mutator})

    source
    |> Ignore.directives()
    |> Ignore.ineffective(occupied)
  end

  # Cap the schema to at most `max` mutants (`--max-mutants`), keeping the first
  # `max` sites in source order. `nil` means no cap. Applied after `finalize/1`
  # (so the sites are already in order) and inside every `from_files/4` (so a
  # poison rebuild stays capped). Only the *run* is bounded — the metamutant
  # sources under `:metamutants` still embed every mutant.
  defp limit(%__MODULE__{} = schema, nil), do: schema

  # mutare:ignore[relational, conditional, logical] equivalent — Options validates :max_mutants as a positive integer or nil, so this defensive guard (limit/2 is private) never sees the values that would distinguish these
  defp limit(%__MODULE__{sites: sites} = schema, max) when is_integer(max) and max > 0,
    do: %{schema | sites: Enum.take(sites, max)}

  # Keep only the sites on an explicitly named `file:line` (`--line`). `nil` keeps
  # every site. Applied here — inside *every* `from_files/4` — so a poison rebuild
  # reapplies it, exactly like `limit/2` (`--max-mutants`): the per-file metamutant
  # still embeds every mutant, so the one compile and poison recovery are unchanged;
  # only the suite-per-mutant run is scoped to these sites. A site's `{file, line}`
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
