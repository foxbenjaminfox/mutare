defmodule Mutare.Transform.Invariants do
  @moduledoc false

  # The `verify_invariants: true` checks: `Mutare.Transform.transform_string_with_sites/2` runs
  # `check!/3` on each rendered file and raises `Mutare.InvariantError` listing every violation.
  #
  # The transform records a mutant (a `Mutare.Site`) and delivers its artifact in one claim
  # (`ClaimState.claim/6`), but nothing structural makes the artifact survive until the metamutant
  # is rendered: a later splice can overwrite it — a host whose target overlaps code where core
  # already placed selectors replaces them with its own raw fallback. A mutant recorded but not
  # selectable runs the unmutated code, so no test can kill it, and nothing downstream notices.
  # These checks read the rendered metamutant back instead of trusting the claim:
  #
  #   * it parses;
  #   * every delivered mutant has a branch that a run activating it alone reaches: a `:branch`
  #     mention outside every other mutant's branch, or, for a dropped clause (a `:delete` site,
  #     which generates no code of its own), such an `:exclusion`;
  #   * no branch or exclusion names an id that was not delivered;
  #   * every delivered mutant appears in a coverage record outside every mutant branch (a record
  #     inside one never fires: it is gated on the baseline), and no record names anything else;
  #   * no delivered mutant renders identically to its original;
  #   * emitting the same source a second time reproduces the first pass exactly — the report
  #     re-renders deferred diffs, and the count pass re-runs the pipeline, both trusting that.
  #
  # The determinism check compares the *emitted tree* (by fingerprint) rather than the rendered
  # metamutant, so the second pass stops before `Sourceror.to_string` — the render is a pure
  # function of that tree, and it is what the pass costs. What is left is the readback's parse,
  # a few per-file comparisons, and one extra plan/emit.
  #
  # "Delivered" is `ClaimState.delivered?/2`, the rule the claim itself applied. The ids compared
  # are the integers the generated code selects on (`Mutare.RuntimeId.local/1`), read back by
  # `Mutare.Manifest`, whose recognisers are the ones poison recovery already relies on.
  # Core's own output satisfies all of this by construction; the checks exist for code core does
  # not control (custom mutators, hosts, extensions) and for regressions.

  alias Mutare.{InvariantError, Manifest, RuntimeId, Site}
  alias Mutare.Transform.{ClaimState, Config}

  @typedoc "The render result `transform_string_with_sites/2` returns."
  @type rendered :: %{
          metamutant: String.t(),
          sites: [Site.t()],
          next_id: pos_integer(),
          dispatch_var: atom(),
          clean_decisions: [Mutare.Transform.CleanRegion.Decision.t()]
        }

  @typedoc "What one emit pass produced, for the determinism comparison."
  @type emitted :: %{
          program: non_neg_integer(),
          sites: [Site.t()],
          next_id: pos_integer(),
          dispatch_var: atom()
        }

  @doc """
  Check `rendered` against `config` (the pass that produced it), emitting the source again with
  `reemit` for the determinism check. Returns `:ok` or raises `Mutare.InvariantError`.
  """
  @spec check!(rendered(), emitted(), Config.t(), (-> emitted())) :: :ok
  def check!(rendered, emitted, %Config{} = config, reemit) when is_function(reemit, 0) do
    delivered = Enum.filter(rendered.sites, &ClaimState.delivered?(config, &1))

    violations =
      readback(rendered, delivered) ++
        unchanged(delivered) ++ determinism(emitted, reemit.())

    if violations == [],
      do: :ok,
      else: raise(InvariantError, file: config.file, violations: violations)
  end

  # --- readback ------------------------------------------------------------

  defp readback(%{metamutant: source, dispatch_var: var, sites: sites}, delivered) do
    case manifest(source, var) do
      {:ok, %Manifest{mentions: mentions}} ->
        by_id = mentions |> Enum.reject(&(&1.kind == :record)) |> Enum.group_by(& &1.id)
        records = for %{kind: :record} = mention <- mentions, do: mention
        delivered_ids = MapSet.new(delivered, &RuntimeId.local/1)
        recorded = Map.new(sites, &{RuntimeId.local(&1), &1})

        branches =
          Enum.flat_map(delivered, fn site ->
            branch_violation(site, Map.get(by_id, RuntimeId.local(site)), recorded)
          end)

        branches ++
          strays(:stray_branch, Map.keys(by_id), delivered_ids, recorded) ++
          missing_records(delivered, records) ++
          strays(:stray_record, Enum.map(records, & &1.id), delivered_ids, recorded)

      {:error, message} ->
        [{:unparseable_metamutant, message}]
    end
  end

  defp manifest(source, var) do
    {:ok, Manifest.from_source(source, var)}
  rescue
    error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, Exception.message(error)}
  end

  # A delivered mutant needs one mention a single-mutant run reaches, of a kind that selects it.
  defp branch_violation(site, nil, _recorded), do: [{:missing_branch, site}]

  defp branch_violation(%Site{} = site, mentions, recorded) do
    id = RuntimeId.local(site)
    selecting = Enum.filter(mentions, &selects?(&1, site))

    cond do
      selecting == [] ->
        [{:missing_branch, site}]

      Enum.any?(selecting, &reached_by?(&1, id)) ->
        []

      true ->
        # Every selecting mention sits in a branch that excludes `id`, so each `within` is a list.
        enclosing = selecting |> Enum.flat_map(& &1.within) |> Enum.uniq() |> Enum.sort()
        [{:unreachable_branch, site, Enum.map(enclosing, &{&1, Map.get(recorded, &1)})}]
    end
  end

  # Whether a run activating `id` alone reaches the mention: it is outside every mutant branch,
  # or inside one that runs under `id` (a clause shared by several guard mutants runs under
  # each of them).
  defp reached_by?(%{within: nil}, _id), do: true
  defp reached_by?(%{within: ids}, id), do: id in ids

  # An exclusion alone changes behaviour only for a dropped clause; any other mutant must have
  # code of its own, or the exclusion merely steps its original aside.
  defp selects?(%{kind: :branch}, _site), do: true
  defp selects?(%{kind: :exclusion}, %Site{operation: :delete}), do: true
  defp selects?(_mention, _site), do: false

  defp strays(kind, ids, delivered_ids, recorded) do
    for id <- ids |> Enum.uniq() |> Enum.sort(),
        not MapSet.member?(delivered_ids, id),
        do: {kind, {id, Map.get(recorded, id)}}
  end

  defp missing_records(delivered, records) do
    recorded = for %{within: nil, id: id} <- records, into: MapSet.new(), do: id

    for site <- delivered,
        not MapSet.member?(recorded, RuntimeId.local(site)),
        do: {:missing_record, site}
  end

  # --- rendered code -------------------------------------------------------

  defp unchanged(delivered) do
    for %Site{original_code: code, mutated_code: code} = site <- delivered,
        do: {:unchanged_mutant, site}
  end

  # --- determinism ---------------------------------------------------------

  defp determinism(emitted, emitted), do: []

  defp determinism(first, second) do
    differences =
      Enum.reject(
        [
          program_difference(first.program, second.program),
          scalar_difference("next id", first.next_id, second.next_id),
          scalar_difference("dispatch variable", first.dispatch_var, second.dispatch_var),
          sites_difference(first.sites, second.sites)
        ],
        &is_nil/1
      )

    [{:nondeterministic_render, differences}]
  end

  defp program_difference(same, same), do: nil
  defp program_difference(_first, _second), do: "the emitted program differs"

  defp scalar_difference(_what, same, same), do: nil

  defp scalar_difference(what, first, second),
    do: "#{what} #{inspect(first)}, then #{inspect(second)}"

  defp sites_difference(same, same), do: nil

  defp sites_difference(first, second) when length(first) != length(second),
    do: "#{length(first)} mutants, then #{length(second)}"

  defp sites_difference(first, second) do
    # mutare:ignore[pattern_swap] equivalent — `!=` is symmetric
    {a, b} = first |> Enum.zip(second) |> Enum.find(fn {a, b} -> a != b end)

    # Sorted: a small map's atom keys come back in atom-table order, not by name.
    fields =
      a
      |> Map.from_struct()
      |> Map.keys()
      |> Enum.filter(&(Map.get(a, &1) != Map.get(b, &1)))
      |> Enum.sort()

    "mutant ##{a.id} (#{a.mutator} at #{a.file}:#{a.line}) changed its " <>
      Enum.map_join(fields, ", ", &"`#{&1}`")
  end
end
