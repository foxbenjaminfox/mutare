defmodule Mutare.Schema do
  @moduledoc """
  The mutant schema for a whole project: every in-scope source transformed into
  its metamutant, with globally-unique mutant ids threaded across files.

  This is the manifest the runner compiles once and the report reads from.
  Files that have no mutation sites, or that *fail to parse*, are left out of
  `:metamutants` (their originals are used as-is) but never crash the build — a
  single unparseable file should not sink the run. A failure *after* a clean
  parse (transform or render) is a bug in this tool, not bad input, and is left
  to crash: see `safe_transform/4`.
  """

  alias Mutare.Site

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

  Options:

    * `:paths` — directories to scan (default `["lib"]`)
    * `:exclude` — wildcard patterns (relative to `root`) to drop
    * `:mutators` — passed through to `Mutare.Transform`
  """
  @spec build(Path.t(), keyword()) :: t()
  def build(root, opts \\ []) do
    paths = Keyword.get(opts, :paths, ["lib"])
    exclude = Keyword.get(opts, :exclude, [])

    root
    |> discover(paths, exclude)
    |> restrict(root, Keyword.get(opts, :only_files))
    |> from_files(root, opts)
  end

  # Intersect discovered files with an explicit set of root-relative paths
  # (e.g. `mix mutare --since master` → files a branch changed).
  defp restrict(files, _root, nil), do: files
  defp restrict(files, root, only), do: Enum.filter(files, &(relative(&1, root) in only))

  @doc "Build a schema from an explicit list of files (paths recorded relative to `root`)."
  @spec from_files([Path.t()], Path.t(), keyword()) :: t()
  def from_files(files, root \\ ".", opts \\ []) do
    # Record the ordered, root-relative input list so the schema can be rebuilt
    # against exactly these files (see `rebuild/3`) without re-discovering.
    initial = %__MODULE__{files: Enum.map(files, &relative(&1, root))}

    files
    |> Enum.reduce({initial, 1}, fn file, {schema, next_id} ->
      add_file(schema, file, root, next_id, opts)
    end)
    |> elem(0)
    |> finalize()
  end

  @doc """
  Rebuild a schema against the *same* files it was originally built from.

  Poison recovery (`Mutare.Runner`) relies on this: re-discovering via `build/2`
  would ignore any restriction baked into the supplied schema (a custom
  `from_files/3` set, or an `:only_files`/`:exclude`-restricted `build/2`) and
  could silently expand to a different file set. Replaying the recorded file list
  preserves the restriction and keeps mutant ids stable (the transform advances
  its id counter even for `:skip_ids`).

  Pass through the original transform opts (e.g. `:mutators`) merged with the new
  `:skip_ids`.
  """
  @spec rebuild(t(), Path.t(), keyword()) :: t()
  def rebuild(%__MODULE__{files: files}, root \\ ".", opts \\ []) do
    files
    |> Enum.map(&Path.join(root, &1))
    |> from_files(root, opts)
  end

  @doc "Total number of mutants in the schema."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{sites: sites}), do: length(sites)

  # --- internals -----------------------------------------------------------

  defp add_file(schema, file, root, next_id, opts) do
    rel = relative(file, root)
    source = File.read!(file)

    case safe_transform(source, rel, next_id, opts) do
      {:ok, _meta, [], next_id} ->
        # Parsed fine but nothing to mutate: keep the original, record source.
        {%{schema | sources: Map.put(schema.sources, rel, source)}, next_id}

      {:ok, meta, sites, next_id} ->
        # Transform hands back the next free id directly, so we never recover it
        # from the last site. Sites accumulate reversed (prepend in O(1) per
        # file, not a growing `++`); finalize/1 flips the list back to order once.
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
  defp safe_transform(source, rel, next_id, opts) do
    opts = Keyword.merge(opts, file: rel, start_id: next_id)
    {meta, sites, next_id} = Mutare.Transform.transform_string(source, opts)
    {:ok, meta, sites, next_id}
  rescue
    error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, error}
  end

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
