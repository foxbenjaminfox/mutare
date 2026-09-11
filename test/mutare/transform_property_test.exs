defmodule Mutare.TransformPropertyTest do
  @moduledoc """
  Property-based companions to `transform_test.exs` / `transform_corpus_test.exs`.
  Those check intended and adversarial examples one assertion at a time; this asserts
  invariants the whole tool rides on over a stream of *randomly generated* modules, so a
  bug in a syntactic corner no hand-written example happened to hit still gets caught.

  Two invariants live here (the renderer half of the "compile once" bet; the *compiles*
  half is `transform_compile_property_test.exs`):

    * **Valid render** — for every valid module `m`, `transform_string(m)` produces source
      that parses as valid Elixir. A single un-parseable mutant would sink the one compile.
    * **No equivalent mutant** — every recorded mutant changes the *rendered* source
      (`Site.original_code != Site.mutated_code`). This is the direct guard on Sourceror's
      clean-meta `:token` footgun (reusing a literal's meta re-renders the *original* text
      even after the value changes — a silent equivalent no-op the score would mis-count),
      the very thing `Mutare.AST.literal/1` exists to prevent.

  The generator (`Mutare.TransformPropertyGenerators`) emits a small, valid-by-construction
  AST and renders it with `Macro.to_string/1` — the tool's real entry point is
  `transform_string(source)`, which runs `Sourceror.parse_string!` itself, so the input
  path is text; `Macro.to_string` needs no token metadata and sidesteps the clean-meta
  footgun the input must not fake. The transform's own `Sourceror.to_string` renderer (the
  thing under test) is still exercised on its output.
  """
  # Pure: only renders/parses strings and inspects sites — flips no global state and
  # defines no modules — so it runs async. See the compile companion for the stateful half.
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.TransformPropertyGenerators, as: Gen

  # The deepened generator (with/fn/try/cond, multi-clause heads, defaults) makes each
  # case cover far more ground — and renders a bigger module twice — so a smaller budget
  # buys comparable coverage at a fraction of the old wall-clock, keeping it fast-loop
  # friendly. Raise locally for a longer soak.
  @numtests 100
  # Cap proper's size. `expr_gen` already bounds expression *depth* (`min(size, 4)`), so size
  # beyond ~16 only inflates leaf magnitudes and function count — cost without structural coverage
  # — while the uncapped tail (single `module_gen` samples up to ~18s near `max_size` 42) is what
  # occasionally pushed a run past the timeout under CPU contention, surfacing as a flaky failure
  # whose stack was an ExUnit-timeout snapshot taken mid-generation.
  @max_size 16
  # Headroom over the per-property budget. The cap above bounds the *worst-case* generation sample,
  # but this property still runs `@numtests` full transform+render cycles, so on a loaded machine
  # (several test suites contending for cores — the exact situation that first tripped this) its
  # wall-clock can climb. A generous timeout keeps a slow-but-correct soak from being scored a
  # failure; these tests are already `:property`-tagged out of the fast loop.
  @moduletag timeout: 600_000
  @moduletag :property

  property "the transform renders valid Elixir with no equivalent mutant",
    numtests: @numtests,
    max_size: @max_size do
    forall module_ast <- Gen.module_gen() do
      source = Macro.to_string(module_ast)

      # Premise: the generated *input* must parse, or a transform failure would be the
      # generator's fault. Valid by construction, so a failure here is a generator bug —
      # surfaced loudly rather than mistaken for a rendering bug.
      case Code.string_to_quoted(source) do
        {:error, reason} ->
          report_failure("generated input did not parse", reason, source, nil)
          false

        {:ok, _} ->
          %{metamutant: metamutant, sites: sites} =
            Mutare.Transform.transform_string_with_sites(source, file: "prop.ex")

          renders_valid?(metamutant, source) and mutants_observable?(sites, source, metamutant)
      end
    end
  end

  defp renders_valid?(metamutant, source) do
    case Code.string_to_quoted(metamutant) do
      {:ok, _} ->
        true

      {:error, reason} ->
        report_failure("metamutant did not parse", reason, source, metamutant)
        false
    end
  end

  # #7: a mutant whose rendered `mutated_code` equals its `original_code` is a silent
  # no-op — it inflates the denominator and can never be killed. The transform should
  # never emit one (the families dedup and reject the original; `AST.literal/1` keeps a
  # changed value from re-rendering as the original text).
  defp mutants_observable?(sites, source, metamutant) do
    case Enum.find(sites, &(&1.original_code == &1.mutated_code)) do
      nil ->
        true

      site ->
        report_failure(
          "equivalent mutant (rendered identically to the original)",
          {site.mutator, site.original_code},
          source,
          metamutant
        )

        false
    end
  end

  # Surface the seed and offending output on a counterexample, actionable straight from
  # the log (PropCheck also records the shrunk seed in its `.ctex` file).
  defp report_failure(what, reason, source, metamutant) do
    IO.puts("""

    PROPERTY FAILURE: #{what}: #{inspect(reason)}
    === source ===
    #{source}
    === metamutant ===
    #{metamutant || "(transform not reached)"}
    """)
  end
end
