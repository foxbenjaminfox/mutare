defmodule Mutare.TransformBaselinePropertyTest do
  @moduledoc """
  The **runtime** leg of the "compile once" bet, generalised: with no mutant active (id 0)
  the metamutant must be observationally identical to the source it was rewritten from.

  `transform_property_test.exs` checks the metamutant *parses* and
  `transform_compile_property_test.exs` checks it *compiles* — both static. Neither catches a
  metamutant that compiles cleanly yet *behaves* differently at baseline. That failure mode is the
  worst kind: a baseline that returns a different value, raises a different error, or reorders a side
  effect manufactures false survivors and false kills across the **entire** run, silently, with the
  score looking perfectly plausible. The transform's subtlest rewrites all live on this seam — the
  tuple-the-scrutinee `case`, default-arg dispatcher forwarding, the pipe-hoisting closure, `super`
  threading, value-discarded match re-export, and `if`-condition binding hoisting — so a regression
  in any of them shows up *here* and (often) nowhere else.

  `transform_corpus_test.exs` asserts the same invariant, but only over nine hand-written modules.
  This generalises it to a stream of randomly generated modules **and** randomly chosen inputs:

      for every generated module `m` and input row `r`, calling each exported `f/arity` of the
      original and of the baseline metamutant yields the same outcome — the same return value, or
      the same raised / thrown / exited reason.

  The generated functions are pure, total, and terminating by construction (bodies reference only
  their own parameters, literals, and total stdlib calls — no recursion, no inter-function calls, no
  time/randomness/process state), so the comparison is deterministic and a divergence is always the
  transform's fault. Blame is kept honest the same way the compile property keeps it: a failing case
  re-checks that the *original* compiled, distinguishing "the transform broke a compiling input"
  from a generator bug.

  Inputs are drawn from a pool that mixes the literals actually appearing in the module (so
  literal-matching `case` / head clauses — tuple-the-scrutinee, head-literal lifting — are reached)
  with a fixed set of common terms, then rotated through each function's parameter slots. Every call
  is dispatched with `apply/3` so referencing the runtime-compiled `Prop` fixture never trips a
  compile-time "undefined module" warning.
  """
  # Compiles two modules per case (original + baseline metamutant), purges them, captures :stderr
  # globally, and flips the global `:persistent_term` selector — must be serial.
  use ExUnit.Case, async: false
  use PropCheck

  alias Mutare.{PropertyProbe, Selector}
  alias Mutare.TransformPropertyGenerators, as: Gen

  # Two compiles per case plus a batch of cheap calls — roughly twice the compile property's
  # per-case cost — so the budget is smaller; the deepened generator keeps coverage high per case.
  # Raise locally for a longer soak.
  @numtests 35
  # Cap proper's size — `expr_gen` already bounds depth (`min(size, 4)`), so larger sizes only
  # inflate leaf/function counts, and the uncapped high-size tail tripped the timeout under load
  # (see `transform_property_test.exs` for the full rationale).
  @max_size 16
  # Headroom over the per-property budget for a slow-but-correct soak under load
  # (see `transform_property_test.exs`).
  @moduletag timeout: 600_000
  @moduletag :property

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  property "the baseline metamutant matches the original on every input",
    numtests: @numtests,
    max_size: @max_size do
    forall module_ast <- Gen.module_gen() do
      source = Macro.to_string(module_ast)

      {metamutant, _sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, file: "prop.ex")

      Selector.put(Selector.baseline())

      case probe_module(source, module_ast) do
        {:error, src_reason} ->
          # The generated input must compile (valid by construction); a failure here is a
          # generator bug, surfaced rather than mistaken for a transform bug.
          report_failure("generated input did not compile", src_reason, source, metamutant)
          false

        {:ok, {specs, original}} ->
          case rerun_module(metamutant, specs) do
            {:error, meta_reason} ->
              report_failure(
                "baseline metamutant did not compile",
                meta_reason,
                source,
                metamutant
              )

              false

            {:ok, baseline} ->
              compare(specs, original, baseline, source, metamutant)
          end
      end
    end
  end

  # First (name, args) whose original and baseline outcomes differ, or `nil` if all agree.
  defp compare(specs, original, baseline, source, metamutant) do
    diverged =
      [specs, original, baseline]
      |> Enum.zip()
      |> Enum.find(fn {_spec, o, b} -> o != b end)

    case diverged do
      nil ->
        true

      {spec, o, b} ->
        report_failure(
          "baseline diverged from the original",
          %{call: spec, original: o, baseline: b},
          source,
          metamutant
        )

        false
    end
  end

  # Compile `source`, derive the probe specs from the module's public exports + the input pool
  # (extracted from `module_ast`), run every probe at baseline, then purge. Returns
  # `{:ok, {specs, outcomes}}` or `{:error, exception}`. The specs are returned so the metamutant
  # is probed with the *identical* calls.
  defp probe_module(source, module_ast) do
    PropertyProbe.with_compiled(source, fn ->
      specs = PropertyProbe.specs(module_ast)
      {specs, Enum.map(specs, &PropertyProbe.probe/1)}
    end)
  end

  # Re-run an already-derived spec list against a freshly compiled `source` (the metamutant).
  defp rerun_module(source, specs) do
    PropertyProbe.with_compiled(source, fn -> Enum.map(specs, &PropertyProbe.probe/1) end)
  end

  # Surface the seed and offending output on a counterexample, actionable straight from the log
  # (PropCheck also records the shrunk seed in its `.ctex` file).
  defp report_failure(what, reason, source, metamutant) do
    IO.puts("""

    BASELINE PROPERTY FAILURE: #{what}: #{inspect(reason)}
    === source ===
    #{source}
    === metamutant ===
    #{metamutant}
    """)
  end
end
