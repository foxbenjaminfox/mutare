defmodule Mutare.RuntimeIdPropertyTest do
  @moduledoc """
  Property pins for the stable per-file runtime identity a namespaced transform gives its
  mutants (NOTES "Stable per-file runtime identities"), over generated modules:

    * **Skipping subtracts generated code, nothing else.** Poison recovery rebuilds with
      `:skip_ids`; the id counter still advances for a skipped id, so for *any* subset of a
      file's ids the rebuild records the same sites (a skipped one marked `poisoned`) with the
      same `next_id`, and its metamutant's manifest attributes exactly the surviving local ids.
    * **Report offsets never enter the metamutant.** A different `:start_id` (an unrelated
      file's candidate count moving this file's report range) shifts every report id by the
      offset and changes nothing else — not a runtime id, not a byte of generated source —
      with or without a skip set (shifted along).
  """
  # Pure: transforms strings and re-parses them; no modules are defined, no selector flipped.
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.{Manifest, Transform}
  alias Mutare.TransformPropertyGenerators, as: Gen

  @numtests 100
  @max_size 16
  @moduletag timeout: 600_000
  @moduletag :property

  @opts [file: "lib/b.ex", runtime_namespace: "lib/b.ex"]

  property "skipping any subset of ids subtracts exactly those sites and nothing else",
    numtests: @numtests,
    max_size: @max_size do
    forall module_ast <- Gen.module_gen() do
      source = Macro.to_string(module_ast)
      {full, sites, next} = Transform.transform_string_with_sites(source, @opts)

      forall skip <- subset(Enum.map(sites, & &1.id)) do
        {skipped, skipped_sites, skipped_next} =
          Transform.transform_string_with_sites(source, [skip_ids: skip] ++ @opts)

        # A skipped id keeps its site — recorded `poisoned`, so the report can list it — and
        # loses only its generated code.
        expected_sites =
          Enum.map(sites, fn site ->
            if MapSet.member?(skip, site.id), do: %{site | poisoned: true}, else: site
          end)

        skipped_next == next and
          skipped_sites == expected_sites and
          manifest_ids(skipped) == MapSet.difference(manifest_ids(full), local_ids(skip, sites))
      end
    end
  end

  property "a report-id offset shifts ids and touches nothing else",
    numtests: @numtests,
    max_size: @max_size do
    forall {module_ast, offset} <- {Gen.module_gen(), integer(0, 10_000)} do
      source = Macro.to_string(module_ast)
      {_full, sites, _next} = Transform.transform_string_with_sites(source, @opts)

      forall skip <- subset(Enum.map(sites, & &1.id)) do
        shifted_skip = MapSet.new(skip, &(&1 + offset))
        base = [skip_ids: skip] ++ @opts
        moved = [start_id: 1 + offset, skip_ids: shifted_skip] ++ @opts

        {a, a_sites, a_next} = Transform.transform_string_with_sites(source, base)
        {b, b_sites, b_next} = Transform.transform_string_with_sites(source, moved)

        a == b and
          b_next == a_next + offset and
          Enum.map(b_sites, & &1.id) == Enum.map(a_sites, &(&1.id + offset)) and
          Enum.map(b_sites, & &1.runtime_id) == Enum.map(a_sites, & &1.runtime_id) and
          Enum.map(b_sites, &{&1.line, &1.original_code, &1.mutated_code}) ==
            Enum.map(a_sites, &{&1.line, &1.original_code, &1.mutated_code})
      end
    end
  end

  # A random subset of `ids`, as a MapSet.
  defp subset(ids) do
    let flags <- vector(length(ids), boolean()) do
      MapSet.new(for {id, true} <- Enum.zip(ids, flags), do: id)
    end
  end

  defp local_id(%{runtime_id: {_file, local}}), do: local

  defp local_ids(report_ids, sites) do
    MapSet.new(for site <- sites, MapSet.member?(report_ids, site.id), do: local_id(site))
  end

  defp manifest_ids(metamutant) do
    %Manifest{regions: regions} = Manifest.from_source(metamutant)
    MapSet.new(Enum.flat_map(regions, & &1.ids))
  end
end
