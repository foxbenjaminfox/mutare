defmodule Mutare.Schema do
  @moduledoc """
  The mutant schema for a whole project: every in-scope source transformed into
  its metamutant, with globally-unique mutant ids threaded across files.

  This is the manifest the runner compiles once and the report reads from.
  Files that have no mutation sites, or that fail to parse/transform, are left
  out of `:metamutants` (their originals are used as-is) but never crash the
  build — a single unparseable file should not sink the run.
  """

  alias Mutare.Site

  @type t :: %__MODULE__{
          sites: [Site.t()],
          metamutants: %{optional(String.t()) => String.t()},
          sources: %{optional(String.t()) => String.t()},
          skipped: [{String.t(), term()}]
        }

  defstruct sites: [], metamutants: %{}, sources: %{}, skipped: []

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
    files
    |> Enum.reduce({%__MODULE__{}, 1}, fn file, {schema, next_id} ->
      add_file(schema, file, root, next_id, opts)
    end)
    |> elem(0)
    |> finalize()
  end

  @doc "Total number of mutants in the schema."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{sites: sites}), do: length(sites)

  # --- internals -----------------------------------------------------------

  defp add_file(schema, file, root, next_id, opts) do
    rel = relative(file, root)
    source = File.read!(file)

    case safe_transform(source, rel, next_id, opts) do
      {:ok, _meta, []} ->
        # Parsed fine but nothing to mutate: keep the original, record source.
        {%{schema | sources: Map.put(schema.sources, rel, source)}, next_id}

      {:ok, meta, sites} ->
        schema = %{
          schema
          | sites: schema.sites ++ sites,
            metamutants: Map.put(schema.metamutants, rel, meta),
            sources: Map.put(schema.sources, rel, source)
        }

        {schema, List.last(sites).id + 1}

      {:error, reason} ->
        {%{schema | skipped: [{rel, reason} | schema.skipped]}, next_id}
    end
  end

  defp safe_transform(source, rel, next_id, opts) do
    opts = Keyword.merge(opts, file: rel, start_id: next_id)
    {meta, sites} = Mutare.Transform.transform_string(source, opts)
    {:ok, meta, sites}
  rescue
    error -> {:error, error}
  end

  defp finalize(%__MODULE__{} = schema), do: %{schema | skipped: Enum.reverse(schema.skipped)}

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
