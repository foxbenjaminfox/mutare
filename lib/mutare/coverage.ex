defmodule Mutare.Coverage do
  @moduledoc """
  The schema doubles as a coverage probe.

  Every mutant lives behind a selector/dispatcher `case` that reads
  `:persistent_term`. That `case`'s subject runs on *every* execution of the
  code path, so a single `:cover` run over the baseline tells us which mutants'
  code is exercised — for free, from the build we already made.

  We work entirely in **metamutant line space**: we locate each selector `case`
  in the rendered metamutant (mapping the mutant ids it hosts → the line of its
  catch-all `_ ->` branch) and intersect with cover's per-line hits. At baseline
  every live selector takes its catch-all, so that line is hit iff the code ran.
  (We key on the catch-all body's line, not the `case` keyword line: cover does
  not count the `case` line of a selector nested on a continuation line.) No
  metamutant↔original line mapping is needed — the original line is for the report.

  A mutant whose selector line no test executes can never be killed
  (`:no_coverage`): skip it and keep it out of the score's denominator.
  """

  # `:cover` is added to the code path at runtime (it lives in OTP's :tools),
  # so it is legitimately undefined at compile time.
  @compile {:no_warn_undefined, :cover}

  @doc "Merge selector indices for several metamutant sources: `%{id => {module, line}}`."
  @spec index([String.t()]) :: %{pos_integer() => {module(), pos_integer()}}
  def index(metamutant_sources) do
    Enum.reduce(metamutant_sources, %{}, fn source, acc ->
      Map.merge(acc, selector_index(source))
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
    error -> {:error, error}
  end

  @doc """
  Map every mutant id to `{module, line}` of the selector `case` that hosts it.

  The line is the selector's catch-all body line — taken at baseline whenever the
  code runs. Delegates the metamutant walk to `Mutare.Metamutant`.
  """
  @spec selector_index(String.t()) :: %{pos_integer() => {module(), pos_integer()}}
  def selector_index(metamutant_source) do
    for clause <- Mutare.Metamutant.selector_clauses(metamutant_source),
        into: %{},
        do: {clause.id, {clause.module, clause.catch_all_line}}
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
