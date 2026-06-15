defmodule Mutare.Coverage do
  @moduledoc """
  The schema doubles as a coverage probe.

  Every mutant lives behind a selector/dispatcher `case` that reads
  `:persistent_term`. That `case`'s subject runs on *every* execution of the
  code path, so a single `:cover` run over the baseline tells us which mutants'
  code is exercised — for free, from the build we already made.

  We work entirely in **metamutant line space**: each mutant's coverage location
  (the `{module, line}` of its selector's catch-all `_ ->` branch) is read from the
  stored `Mutare.Manifest` and intersected with cover's per-line hits. At baseline
  every live selector takes its catch-all, so that line is hit iff the code ran.
  (The manifest keys on the catch-all body's line, not the `case` keyword line:
  cover does not count the `case` line of a selector nested on a continuation
  line.) No metamutant↔original line mapping is needed — the original line is for
  the report.

  A mutant whose selector line no test executes can never be killed
  (`:no_coverage`): skip it and keep it out of the score's denominator.
  """

  require Logger

  alias Mutare.Manifest

  # `:cover` is added to the code path at runtime (it lives in OTP's :tools),
  # so it is legitimately undefined at compile time.
  @compile {:no_warn_undefined, :cover}

  @doc """
  Merge the per-file manifests' coverage locations: `%{id => {module, line}}`.

  Mutant ids are globally unique across files, so the maps never collide.
  """
  @spec index([Manifest.t()]) :: %{pos_integer() => {module(), pos_integer()}}
  def index(manifests) do
    Enum.reduce(manifests, %{}, fn manifest, acc ->
      Map.merge(acc, Manifest.coverage(manifest))
    end)
  end

  @doc "Per-line hit set `{module, line}` from a `.coverdata` file."
  @spec hits(Path.t()) :: {:ok, MapSet.t()} | {:error, term()}
  def hits(coverdata_path) do
    if File.exists?(coverdata_path) do
      {:ok, hit_lines(coverdata_path)}
    else
      {:error, :no_coverdata}
    end
  rescue
    # Broad on purpose: `:cover` variance surfaces as MatchError (start/import),
    # CaseClauseError (analyse shape), or ErlangError — all degrade to `:run_all`
    # (slow-but-correct), never a false `:no_coverage`. Log so a genuine defect
    # doesn't hide as a silent, mysteriously-slow run-all fallback.
    error ->
      Logger.warning(
        "coverage probe failed (#{coverdata_path}), falling back to run-all: " <>
          Exception.message(error)
      )

      {:error, error}
  end

  # --- cover ---------------------------------------------------------------

  defp hit_lines(coverdata_path) do
    ensure_cover_loaded!()
    # Fresh cover each call so repeated runs in one VM (tests) don't accumulate.
    _ = :cover.stop()
    {:ok, _pid} = :cover.start()
    :ok = :cover.import(String.to_charlist(coverdata_path))

    for {{module, line}, {covered, _not_covered}} <- analyse_lines(),
        covered > 0 and line > 0,
        into: MapSet.new(),
        do: {module, line}
  end

  defp analyse_lines do
    # OTP versions differ: {:result, ok, fail} (multi-module), {:ok, list}, or
    # {list, fail}. Normalise to the list of {{module, line}, {cov, not_cov}}.
    case :cover.analyse(:coverage, :line) do
      {:result, results, _failures} -> results
      {:ok, results} -> results
      {results, _failures} when is_list(results) -> results
    end
  end

  # `:cover` ships in OTP's `:tools`, which a mix project doesn't put on the code
  # path by default — add it from the OTP lib dir on demand.
  defp ensure_cover_loaded! do
    unless Code.ensure_loaded?(:cover) do
      [to_string(:code.root_dir()), "lib", "tools-*", "ebin"]
      |> Path.join()
      |> Path.wildcard()
      |> case do
        [ebin | _] -> :code.add_pathz(String.to_charlist(ebin))
        [] -> :ok
      end

      Code.ensure_loaded(:cover)
    end
  end
end
