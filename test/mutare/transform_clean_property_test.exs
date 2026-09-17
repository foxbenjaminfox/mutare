defmodule Mutare.TransformCleanPropertyTest do
  @moduledoc """
  The **clean-region** property: a clean implementation never changes what any selection
  computes.

  A clean region (`Mutare.Transform.CleanRegion`) replaces every selector inside a lifted
  group or an in-place `:do` body with one decision that the active mutant lies elsewhere,
  and then runs a copy of the source. Two things can go wrong, and neither shows at
  baseline (which always takes the instrumented implementation):

    * the copy differs from the source it claims to be — a scoping slip in
      `Mutare.Transform.CleanPath` that admitted something it should not have; or
    * the interval is wrong — a mutant inside the region selects the clean copy and so
      silently runs the original (a false survivor), or an outside id misses it.

  So the comparison is differential and total over selections:

      for every generated module, the metamutant with clean regions and the metamutant
      without them record the same sites and, under baseline, every mutant id, and an id
      no site owns, give the same outcome for every probed call.

  The control is the transform's own `clean_functions: false`, so a divergence is the
  region's fault by construction. `clean_threshold: 1` gives every eligible region a clean
  implementation, including the single-site ones the default policy skips. A companion test
  pins that the generator's modules do acquire clean regions, so the property cannot pass
  vacuously.
  """
  # Compiles two modules per case, purges them, captures :stderr globally, and flips the
  # global `:persistent_term` selector across every mutant id — must be serial.
  use ExUnit.Case, async: false
  use PropCheck

  alias Mutare.{PropertyProbe, Selector, Transform}
  alias Mutare.TransformPropertyGenerators, as: Gen

  # Two compiles plus two full selection sweeps per case.
  @numtests 30
  # Cap proper's size (see `transform_property_test.exs` for the full rationale).
  @max_size 16
  @moduletag timeout: 600_000
  @moduletag :property

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  property "clean regions change no outcome under any selection",
    numtests: @numtests,
    max_size: @max_size do
    forall module_ast <- Gen.module_gen() do
      source = Macro.to_string(module_ast)
      clean = Transform.transform_string_with_sites(source, file: "prop.ex", clean_threshold: 1)

      control =
        Transform.transform_string_with_sites(source, file: "prop.ex", clean_functions: false)

      selections = [Selector.baseline(), clean.next_id + 1 | Enum.map(clean.sites, & &1.id)]

      with true <- same_sites?(clean, control, source),
           {:ok, {specs, expected}} <- sweep(control.metamutant, selections, module_ast, nil),
           {:ok, {_specs, actual}} <- sweep(clean.metamutant, selections, module_ast, specs) do
        agree?(selections, specs, expected, actual, source, clean.metamutant)
      else
        false ->
          false

        {:error, reason} ->
          report_failure("a metamutant did not compile", reason, source, clean.metamutant)
          false
      end
    end
  end

  test "the generator's modules acquire clean regions" do
    decisions =
      for seed <- 1..25,
          {:ok, module_ast} = PropCheck.produce(Gen.module_gen(), seed),
          decision <-
            Transform.transform_string_with_sites(Macro.to_string(module_ast),
              file: "prop.ex",
              clean_threshold: 1
            ).clean_decisions,
          do: decision

    clean = Enum.count(decisions, &(&1.verdict == :clean))
    assert clean > 0
    assert clean * 2 > length(decisions), "most generated regions should be clean-eligible"
    assert Enum.any?(decisions, &(&1.verdict == :clean and &1.delivery == :lifted))
    assert Enum.any?(decisions, &(&1.verdict == :clean and &1.delivery == :in_place))
  end

  defp same_sites?(clean, control, source) do
    if clean.sites == control.sites and clean.next_id == control.next_id do
      true
    else
      report_failure("clean regions changed the recorded sites", :sites, source, clean.metamutant)
      false
    end
  end

  # Compile once, then probe under each selection by flipping the selector. `specs` is derived
  # from the first compile and reused, so both metamutants answer the identical calls.
  defp sweep(metamutant, selections, module_ast, specs) do
    PropertyProbe.with_compiled(metamutant, fn ->
      specs = specs || PropertyProbe.specs(module_ast)

      outcomes =
        Enum.map(selections, fn selection ->
          Selector.put(selection)
          Enum.map(specs, &PropertyProbe.probe/1)
        end)

      Selector.put(Selector.baseline())
      {specs, outcomes}
    end)
  end

  defp agree?(selections, specs, expected, actual, source, metamutant) do
    diverged =
      [selections, expected, actual]
      |> Enum.zip()
      |> Enum.find_value(fn {selection, expected, actual} ->
        [specs, expected, actual]
        |> Enum.zip()
        |> Enum.find_value(fn {spec, e, a} ->
          if e != a, do: %{selection: selection, call: spec, without: e, with_clean: a}
        end)
      end)

    case diverged do
      nil ->
        true

      divergence ->
        report_failure("a clean region changed an outcome", divergence, source, metamutant)
        false
    end
  end

  defp report_failure(what, reason, source, metamutant) do
    IO.puts("""

    CLEAN REGION PROPERTY FAILURE: #{what}: #{inspect(reason)}
    === source ===
    #{source}
    === metamutant ===
    #{metamutant}
    """)
  end
end
