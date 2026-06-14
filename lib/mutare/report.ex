defmodule Mutare.Report do
  @moduledoc """
  Turns results into the product: a list of surviving mutants, each rendered as
  a diff at `file:line`.

  Diffs are patched against the **original** source via `Sourceror.patch_string`
  at the site's recorded range, so the rest of every line stays byte-identical
  and a survivor reads as a precise one-line change.
  """

  alias Mutare.{Result, Site}

  @doc "Apply a single mutation to the original source string."
  @spec patch(Site.t(), String.t()) :: String.t()
  def patch(%Site{} = site, source) do
    Sourceror.patch_string(source, [%{range: site.range, change: site.mutated_code}])
  end

  @doc "Header line for a surviving mutant, e.g. `lib/x.ex:42  [relational, in-place]  SURVIVED`."
  @spec header(Site.t()) :: String.t()
  def header(%Site{} = site) do
    "#{site.file}:#{site.line}  [#{site.mutator}, #{kind(site.kind)}]  SURVIVED"
  end

  defp kind(:in_place), do: "in-place"
  defp kind(:lifted), do: "lifted"

  @doc "A `-`/`+` diff of the line(s) the mutation touches."
  @spec diff(Site.t(), String.t()) :: String.t()
  def diff(%Site{operation: :delete} = site, source) do
    # Clause-drop: the whole clause is removed, so show its lines as deletions.
    lines = String.split(source, "\n")

    site.range.start[:line]..site.range.end[:line]
    |> Enum.map_join("\n", &("-" <> line_at(lines, &1)))
  end

  def diff(%Site{} = site, source) do
    patched = patch(site, source)
    original_lines = String.split(source, "\n")
    patched_lines = String.split(patched, "\n")

    site.range.start[:line]..site.range.end[:line]
    |> Enum.flat_map(fn n ->
      ["-" <> line_at(original_lines, n), "+" <> line_at(patched_lines, n)]
    end)
    |> Enum.join("\n")
  end

  @doc "Full diff block (header + diff) for one survivor."
  @spec survivor(Site.t(), String.t()) :: String.t()
  def survivor(%Site{} = site, source) do
    header(site) <> "\n" <> diff(site, source)
  end

  @doc """
  Render the whole report from results and a `%{file => original_source}` map.
  """
  @spec render([Result.t()], %{optional(String.t()) => String.t()}) :: String.t()
  def render(results, sources) do
    survivors = Enum.filter(results, &(&1.status == :survived))

    blocks =
      Enum.map_join(survivors, "\n\n", fn %Result{site: site} ->
        survivor(site, Map.fetch!(sources, site.file))
      end)

    [survivor_section(survivors, blocks), summary(results)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Mutation score as a percentage: `killed / (total − no_coverage − ignored)`.
  Returns `100.0` when the denominator is zero (nothing to test).
  """
  @spec score([Result.t()]) :: float()
  def score(results) do
    # A timeout is a kill (the mutation caused a hang).
    killed = count(results, :killed) + count(results, :timeout)
    excluded = count(results, :no_coverage) + count(results, :ignored) + count(results, :poisoned)
    denominator = length(results) - excluded

    if denominator <= 0, do: 100.0, else: killed / denominator * 100
  end

  @doc """
  Whether `results` meet a minimum score (a percentage). A `nil` minimum always
  passes — this is the CI gate's decision, kept pure here so it is testable.
  """
  @spec passes_gate?([Result.t()], number() | nil) :: boolean()
  def passes_gate?(_results, nil), do: true
  def passes_gate?(results, min_score), do: score(results) >= min_score

  @doc "One-line tally, e.g. `mutation score: 66.7%  (2 killed, 1 survived, 3 total)`."
  @spec summary([Result.t()]) :: String.t()
  def summary(results) do
    killed = count(results, :killed)
    timeout = count(results, :timeout)
    survived = count(results, :survived)
    no_coverage = count(results, :no_coverage)
    ignored = count(results, :ignored)
    poisoned = count(results, :poisoned)

    tally =
      ["#{killed} killed"]
      |> maybe_add(timeout > 0, "#{timeout} timeout")
      |> Kernel.++(["#{survived} survived"])
      |> maybe_add(no_coverage > 0, "#{no_coverage} no-coverage")
      |> maybe_add(ignored > 0, "#{ignored} ignored")
      |> maybe_add(poisoned > 0, "#{poisoned} poisoned")
      |> Kernel.++(["#{length(results)} total"])
      |> Enum.join(", ")

    "mutation score: #{:erlang.float_to_binary(score(results), decimals: 1)}%  (#{tally})"
  end

  # --- internals -----------------------------------------------------------

  defp survivor_section([], _blocks), do: ""
  defp survivor_section(_survivors, blocks), do: blocks

  defp line_at(lines, n), do: Enum.at(lines, n - 1, "")

  defp count(results, status), do: Enum.count(results, &(&1.status == status))

  defp maybe_add(list, true, item), do: list ++ [item]
  defp maybe_add(list, false, _item), do: list
end
