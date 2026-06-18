defmodule Mutare.Schema do
  @moduledoc """
  The mutant schema for a whole project: every in-scope source transformed into
  its metamutant, with globally-unique mutant ids threaded across files.

  This is what the runner compiles once and the report reads from.
  Files that have no mutation sites, or that *fail to parse*, are left out of
  `:metamutants` (their originals are used as-is) but never crash the build — a
  single unparseable file should not sink the run. A failure *after* a clean
  parse (transform or render) is a bug in this tool, not bad input, and is left
  to crash: see `safe_transform/5`.

  We store each file's rendered metamutant source (under `:metamutants`) but not
  a precomputed `Mutare.Manifest`: the manifest (generated line ranges, for
  mapping a compile error back to a mutant) is read *only* on a failed compile,
  so `Mutare.Poison` builds it lazily from the metamutant for the offending
  file(s). Building it eagerly here was the scan's dominant cost — a full
  `Sourceror.parse_string!` of a ~40k-line metamutant takes *minutes* — and was
  thrown away on every healthy run.
  """

  alias Mutare.{Options, Site}

  @type t :: %__MODULE__{
          files: [String.t()],
          sites: [Site.t()],
          metamutants: %{optional(String.t()) => String.t()},
          sources: %{optional(String.t()) => String.t()},
          skipped: [{String.t(), term()}]
        }

  defstruct files: [], sites: [], metamutants: %{}, sources: %{}, skipped: []

  @doc """
  Build a schema by discovering files under `root`.

  `opts` is a `Mutare.Options` (or a keyword list resolved into one). It reads
  `:paths` (directories to scan recursively, or individual `.ex` files),
  `:exclude` (wildcard patterns dropped),
  `:only_files` (restrict to an explicit set, e.g. `--since`), and `:mutators`
  (passed through to `Mutare.Transform`).
  """
  @spec build(Path.t(), Options.t() | keyword()) :: t()
  def build(root, opts \\ []) do
    options = Options.new(opts)

    root
    |> discover(scoped_paths(options), options.exclude)
    |> restrict(root, options.only_files)
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

  defp join_scope(".", base), do: base
  defp join_scope(dir, base), do: Path.join(dir, base)

  # Intersect discovered files with an explicit set of root-relative paths
  # (e.g. `mix mutare --since master` → files a branch changed).
  defp restrict(files, _root, nil), do: files
  defp restrict(files, root, only), do: Enum.filter(files, &(relative(&1, root) in only))

  @doc """
  Build a schema from an explicit list of files (paths recorded relative to `root`).

  `skip_ids` is poison-recovery state (mutant ids to drop), threaded separately
  from the user `Options` because it is internal transform plumbing, not config.
  """
  @spec from_files([Path.t()], Path.t(), Options.t() | keyword(), MapSet.t()) :: t()
  def from_files(files, root \\ ".", opts \\ [], skip_ids \\ MapSet.new()) do
    options = Options.new(opts)
    on_scan = options.on_scan || fn _progress -> :ok end
    total = length(files)

    # Record the ordered, root-relative input list so the schema can be rebuilt
    # against exactly these files (see `rebuild/4`) without re-discovering.
    initial = %__MODULE__{files: Enum.map(files, &relative(&1, root))}

    files
    |> Enum.with_index(1)
    |> Enum.reduce({initial, 1}, fn {file, done}, {schema, next_id} ->
      {schema, next_id} = add_file(schema, file, root, next_id, options, skip_ids)
      # Live scan progress (no-op unless a hook is set; cleared by `rebuild/4`, so
      # poison-recovery re-scans stay silent). `next_id - 1` is the running mutant
      # tally, since the id counter starts at 1.
      on_scan.(%{done: done, total: total, found: next_id - 1})
      {schema, next_id}
    end)
    |> elem(0)
    |> finalize()
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

  defp add_file(schema, file, root, next_id, options, skip_ids) do
    rel = relative(file, root)
    source = File.read!(file)

    case safe_transform(source, rel, next_id, options, skip_ids) do
      {:ok, _meta, [], next_id} ->
        # Parsed fine but nothing to mutate: keep the original, record source.
        {%{schema | sources: Map.put(schema.sources, rel, source)}, next_id}

      {:ok, meta, sites, next_id} ->
        # Transform hands back the next free id directly, so we never recover it
        # from the last site. Sites accumulate reversed (prepend in O(1) per
        # file, not a growing `++`); finalize/1 flips the list back to order once.
        #
        # We store the rendered metamutant but no precomputed manifest: that's
        # read only on a failed compile, so `Mutare.Poison` re-derives it lazily
        # from this source for the offending file(s) (see `Mutare.Poison.ids/2`).
        schema = %{
          schema
          | sites: Enum.reverse(sites, schema.sites),
            metamutants: Map.put(schema.metamutants, rel, meta),
            sources: Map.put(schema.sources, rel, source)
        }

        {schema, next_id}

      {:error, reason} ->
        {%{schema | skipped: [{rel, reason} | schema.skipped]}, next_id}
    end
  end

  # Only an *unparseable source* is skipped: the three exceptions below are the
  # ones Elixir's parser (via `Sourceror.parse_string!`) raises on malformed
  # input, and there is nothing the tool can do about a file it cannot read as
  # Elixir. Every other exception means the parse succeeded and we then failed
  # while transforming or rendering — i.e. a bug in this tool (a bad clause, a
  # construct the transform mishandles, a Sourceror formatter crash). Swallowing
  # those as "skipped files" is exactly how the two compile-poisoning bugs hid
  # (see NOTES.md); let them crash so they surface.
  #
  # The transform runs in a **throwaway process** (`Task.async`/`await`): its
  # heavy, short-lived ASTs — the rendered metamutant tree, Sourceror's render
  # buffers — die with that process instead of accumulating in the scan's
  # long-lived heap, where they otherwise made every GC scan the growing set of
  # held metamutants and inflated a big file's transform several-fold (see NOTES
  # "Scan is transform-bound, and the loop heap makes it worse"). The result is
  # plain data (strings, sites, id), cheap to copy back, and `from_files` awaits
  # each file before the next, so sequential `start_id` threading is unchanged.
  #
  # The worker classifies its own outcome rather than crashing: an unparseable
  # source degrades to `{:error, _}` (a skipped file); any *other* exception is a
  # tool bug, captured with its stacktrace and **re-raised in this process** — so
  # it still surfaces with its original type and trace (the `assert_raise`
  # contract, and the "let it crash so it surfaces" rule above), not as an opaque
  # `Task` exit. Catching in the worker (not letting it crash) is what keeps the
  # surfaced error faithful across the process hop.
  defp safe_transform(source, rel, next_id, %Options{} = options, skip_ids) do
    opts = transform_opts(options) ++ [file: rel, start_id: next_id, skip_ids: skip_ids]

    outcome =
      fn ->
        try do
          {meta, sites, next_id} = Mutare.Transform.transform_string(source, opts)
          {:ok, meta, sites, next_id}
        rescue
          error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
            {:error, error}

          other ->
            {:raise, other, __STACKTRACE__}
        end
      end
      |> Task.async()
      |> Task.await(:infinity)

    case outcome do
      {:raise, error, stacktrace} -> reraise(error, stacktrace)
      result -> result
    end
  end

  # Forward `:mutators` (when set) and `:macros` to the transform. A `nil` `:mutators`
  # lets `Mutare.Transform` use its default set (we never hard-code that default here);
  # when set it carries the resolved `Mutare.Mutator.Spec`s — including any `{module, opts}`
  # config (e.g. a mutator's `call_option_keys: false`). `:macros` carries the resolved
  # `Mutare.Macro.Spec`s (known-macro argument routing), `[]` when none; the transform
  # merges them with the built-ins and any enabled mutator's `macros/0`.
  defp transform_opts(%Options{mutators: mutators, macros: macros}) do
    macro_opts = if macros == [], do: [], else: [macros: macros]
    if(mutators == nil, do: [], else: [mutators: mutators]) ++ macro_opts
  end

  defp finalize(%__MODULE__{} = schema) do
    %{schema | sites: Enum.reverse(schema.sites), skipped: Enum.reverse(schema.skipped)}
  end

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
