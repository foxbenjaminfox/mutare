defmodule Mutare.Runner.Hydrate do
  @moduledoc false

  # The read side of the scan's diff deferral. When a `mix mutare` run scans with
  # `context.defer_site_code` (the common case — reporters that show only survivors, no
  # `--verbose`/`:json`/`:html`), each `Mutare.Site` is built *without* its rendered
  # `original_code`/`mutated_code`: the per-mutant `Sourceror` render dominates the build, yet
  # only the handful of mutants a reporter actually shows ever need the diff text. This module
  # fills that text back in, on demand, for exactly those sites.
  #
  # A site needs code only when its result is *displayed*: a `leave_behind` status
  # (`:survived`/`:timeout`/`:atom_exhausted`/`:harness_error`) leaves a line in the live
  # reporter as it streams, and survivors flow on into the final/SARIF reports. Killed and
  # no-coverage mutants — the overwhelming majority — never display a diff, so their code is
  # never rendered. (`:json`/`:html`, which emit *every* mutant's replacement, force eager
  # rendering up front instead, so this module is bypassed for them.)
  #
  # Re-derivation is a per-file re-render (`Mutare.Transform.render_sites/2`) at the file's
  # original `:start_id`, **memoised once per file** (an `Agent`): the pipeline is deterministic
  # for one source, so the re-rendered ids and code line up with the schema's exactly. Building
  # sites without code never changed any id/tree/count, so this re-render reproduces the eager
  # result byte-for-byte. A miss renders outside the agent (so concurrent workers don't
  # serialise on it); a benign race just re-renders a file twice to the identical map.

  alias Mutare.{Options, Result, Schema, Site, Transform}
  alias Mutare.Result.Status

  @enforce_keys [:options, :sources, :starts, :cache]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            options: Options.t(),
            sources: %{optional(String.t()) => String.t()},
            starts: %{optional(String.t()) => pos_integer()},
            cache: pid()
          }

  @doc """
  A hydrator for `schema` when the run deferred site diffs, else `nil`.

  `nil` is the eager path — sites already carry their code, so `result/2` is a no-op and the
  caller needs no hydration. Starts a memo `Agent`; pair with `stop/1`.
  """
  @spec maybe_new(Schema.t(), Mutare.Run.Context.t()) :: t() | nil
  def maybe_new(_schema, %{defer_site_code: false}), do: nil

  def maybe_new(%Schema{} = schema, %{defer_site_code: true, options: options}) do
    {:ok, cache} = Agent.start_link(fn -> %{} end)

    %__MODULE__{
      options: options,
      sources: schema.sources,
      starts: file_starts(schema.sites),
      cache: cache
    }
  end

  @doc "Stop the memo agent. A no-op for the eager (`nil`) path."
  @spec stop(t() | nil) :: :ok
  def stop(nil), do: :ok
  def stop(%__MODULE__{cache: cache}), do: Agent.stop(cache)

  @doc """
  Fill in `result`'s site diff code when the result will be displayed and the code was deferred.

  A no-op (returns `result` unchanged) for the eager path (`nil`), a non-displayed status, or a
  site already carrying code — so it is safe to call on every result.
  """
  @spec result(t() | nil, Result.t()) :: Result.t()
  def result(nil, result), do: result

  def result(%__MODULE__{} = h, %Result{site: %Site{original_code: nil} = site} = result) do
    if displayed?(result.status),
      do: %{result | site: hydrate(h, site)},
      else: result
  end

  # Already carries code (eager site, or a previously-hydrated one): nothing to do.
  def result(%__MODULE__{}, %Result{} = result), do: result

  # A status whose result leaves a line behind in the live reporter — the only ones that render a
  # diff as the run streams. Derived from the `Mutare.Result.Status` registry so a new
  # leave-behind status is covered without editing this module.
  defp displayed?(status), do: Status.fetch!(status).leave_behind != nil

  defp hydrate(%__MODULE__{} = h, %Site{} = site) do
    case Map.get(file_codes(h, site.file), site.id) do
      {original_code, mutated_code} ->
        %{site | original_code: original_code, mutated_code: mutated_code}

      # Defensive: the deterministic re-render always covers the file's ids, so a miss can't
      # happen — but if it ever did, leave the site as-is rather than crash a reporting path.
      nil ->
        site
    end
  end

  # `%{id => {original_code, mutated_code}}` for `file`, rendered once and memoised. The render
  # runs outside the agent so concurrent workers don't serialise on a slow re-render.
  defp file_codes(%__MODULE__{cache: cache} = h, file) do
    case Agent.get(cache, &Map.get(&1, file)) do
      nil ->
        codes = render_file_codes(h, file)
        Agent.update(cache, &Map.put_new(&1, file, codes))
        codes

      codes ->
        codes
    end
  end

  defp render_file_codes(%__MODULE__{} = h, file) do
    source = Map.fetch!(h.sources, file)
    start_id = Map.fetch!(h.starts, file)
    opts = Schema.render_opts(h.options, file, start_id)

    source
    |> Transform.render_sites(opts)
    |> Map.new(&{&1.id, {&1.original_code, &1.mutated_code}})
  end

  # Each file's `:start_id` — the smallest mutant id among its sites (ids are claimed in
  # ascending order within a file, so the first site's id is the start id; `min` is robust
  # regardless of ordering). Poisoned sites keep their id, so they're included.
  defp file_starts(sites) do
    Enum.reduce(sites, %{}, fn %Site{file: file, id: id}, acc ->
      Map.update(acc, file, id, &min(&1, id))
    end)
  end
end
