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

  Alongside each file's metamutant source we store its `Mutare.Manifest` (under
  `:manifests`): the per-mutant coverage locations and generated line ranges,
  computed once here so the coverage probe and poison recovery read them back
  rather than re-parsing the rendered metamutant on every probe and compile error.
  """

  alias Mutare.{Manifest, Options, Site}

  @type t :: %__MODULE__{
          files: [String.t()],
          sites: [Site.t()],
          metamutants: %{optional(String.t()) => String.t()},
          manifests: %{optional(String.t()) => Manifest.t()},
          sources: %{optional(String.t()) => String.t()},
          skipped: [{String.t(), term()}]
        }

  defstruct files: [], sites: [], metamutants: %{}, manifests: %{}, sources: %{}, skipped: []

  @doc """
  Build a schema by discovering files under `root`.

  `opts` is a `Mutare.Options` (or a keyword list resolved into one). It reads
  `:paths` (directories to scan), `:exclude` (wildcard patterns dropped),
  `:only_files` (restrict to an explicit set, e.g. `--since`), and `:mutators`
  (passed through to `Mutare.Transform`).
  """
  @spec build(Path.t(), Options.t() | keyword()) :: t()
  def build(root, opts \\ []) do
    options = Options.new(opts)

    root
    |> discover(options.paths, options.exclude)
    |> restrict(root, options.only_files)
    |> from_files(root, options)
  end

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

    # Record the ordered, root-relative input list so the schema can be rebuilt
    # against exactly these files (see `rebuild/4`) without re-discovering.
    initial = %__MODULE__{files: Enum.map(files, &relative(&1, root))}

    files
    |> Enum.reduce({initial, 1}, fn file, {schema, next_id} ->
      add_file(schema, file, root, next_id, options, skip_ids)
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
        # The manifest (per-mutant coverage location + generated line ranges) is
        # built here, once, from the rendered metamutant — so the coverage probe
        # and poison recovery read it back instead of each re-parsing the source.
        # A rebuild (poison recovery) regenerates it for the new metamutant, so it
        # always matches the stored source.
        schema = %{
          schema
          | sites: Enum.reverse(sites, schema.sites),
            metamutants: Map.put(schema.metamutants, rel, meta),
            manifests: Map.put(schema.manifests, rel, Manifest.from_source(meta)),
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
  defp safe_transform(source, rel, next_id, %Options{} = options, skip_ids) do
    opts = transform_opts(options) ++ [file: rel, start_id: next_id, skip_ids: skip_ids]
    {meta, sites, next_id} = Mutare.Transform.transform_string(source, opts)
    {:ok, meta, sites, next_id}
  rescue
    error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, error}
  end

  # Only forward `:mutators` when set; `nil` lets `Mutare.Transform` use its
  # default mutator set (we never hard-code that default here).
  defp transform_opts(%Options{mutators: nil}), do: []
  defp transform_opts(%Options{mutators: modules}), do: [mutators: modules]

  defp finalize(%__MODULE__{} = schema) do
    %{schema | sites: Enum.reverse(schema.sites), skipped: Enum.reverse(schema.skipped)}
  end

  defp discover(root, paths, exclude) do
    excluded = Enum.flat_map(exclude, &Path.wildcard(Path.join(root, &1)))

    paths
    |> Enum.flat_map(fn path -> Path.wildcard(Path.join([root, path, "**", "*.ex"])) end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in excluded))
    |> Enum.sort()
  end

  defp relative(file, root) do
    file |> Path.relative_to(root) |> to_string()
  end
end
