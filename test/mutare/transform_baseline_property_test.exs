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

  import ExUnit.CaptureIO, only: [with_io: 2]

  alias Mutare.Selector
  alias Mutare.TransformPropertyGenerators, as: Gen

  # Two compiles per case plus a batch of cheap calls — roughly twice the compile property's
  # per-case cost — so the budget is smaller; the deepened generator keeps coverage high per case.
  # Raise locally for a longer soak.
  @numtests 35
  @moduletag timeout: 300_000
  @moduletag :property

  # The generator's fixed module name. Held as an atom so it is only ever reached via `apply/3`
  # (never a compile-time remote call to a module that does not exist when this test compiles).
  @module Prop

  # Common terms mixed in with the module's own literals, so atom / boolean / nil clauses (whose
  # literals the numeric/string extractor below does not collect) are still reachable.
  @fixed_inputs [0, 1, -1, 2, :ok, :error, :pending, :alpha, :beta, true, false, nil, "ab"]

  # How many distinct input rows to try per exported function.
  @rows_per_function 6

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  property "the baseline metamutant matches the original on every input", numtests: @numtests do
    forall module_ast <- Gen.module_gen() do
      source = Macro.to_string(module_ast)
      {metamutant, _sites, _next_id} = Mutare.transform_string(source, file: "prop.ex")
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
    with_compiled(source, fn ->
      specs = build_specs(exported(@module), input_pool(module_ast))
      {specs, Enum.map(specs, &probe/1)}
    end)
  end

  # Re-run an already-derived spec list against a freshly compiled `source` (the metamutant).
  defp rerun_module(source, specs) do
    with_compiled(source, fn -> Enum.map(specs, &probe/1) end)
  end

  # Run one probe, capturing a normal return *or* a raise/throw/exit, so the original and the
  # baseline metamutant are compared on identical, total outcomes (the tags keep a returned value
  # from ever colliding with a captured failure).
  defp probe({name, args}) do
    {:value, apply(@module, name, args)}
  rescue
    error -> {:raised, error.__struct__}
  catch
    kind, value -> {:caught, kind, value}
  end

  # Public functions of the compiled fixture (`{name, arity}`), default-arg arities included.
  # Reached via `apply/3` to avoid a compile-time remote call to the not-yet-existing module.
  defp exported(module), do: apply(module, :__info__, [:functions])

  # For each exported `name/arity`, a handful of argument rows: each rotates a window across the
  # pool, so successive rows hit different slot combinations (and, with the module's own literals
  # up front, frequently land on a literal-matching clause). Deduped; arity 0 collapses to one.
  defp build_specs(exports, pool) do
    n = length(pool)

    for {name, arity} <- exports,
        i <- 0..(@rows_per_function - 1) do
      args = for j <- 0..(arity - 1)//1, do: Enum.at(pool, rem(i + j, n))
      {name, args}
    end
    |> Enum.uniq()
  end

  # Candidate input terms: the numeric/string literals actually present in the module (so
  # literal-matching clauses are reachable) ahead of a fixed pool of common terms, capped.
  defp input_pool(module_ast) do
    (literals(module_ast) ++ @fixed_inputs)
    |> Enum.uniq()
    |> Enum.take(14)
  end

  # Collect the integer/float/binary *value* literals from the generated AST. In this generator
  # those node shapes are only ever data (operands, head/clause patterns, guard bounds) — never
  # structure — so no filtering is needed; atoms (which double as identifiers/operators) are left
  # to the fixed pool.
  defp literals(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        if is_integer(node) or is_float(node) or is_binary(node),
          do: {node, [node | acc]},
          else: {node, acc}
      end)

    Enum.reverse(acc)
  end

  # Compile a source string, run `fun` against the loaded module, then purge every module it
  # defined so the fixed `Prop` name never clashes across cases. Swallows the (legitimate)
  # redefining/unused/unreachable warnings. Returns `{:ok, fun.()}` or `{:error, exception}`.
  defp with_compiled(source, fun) do
    {result, _io} =
      with_io(:stderr, fn ->
        try do
          modules = Code.compile_string(source)
          value = fun.()
          Enum.each(modules, fn {module, _binary} -> purge(module) end)
          {:ok, value}
        rescue
          e ->
            # A failed compile may leave a partial definition behind; clear it best-effort.
            purge(@module)
            {:error, e}
        end
      end)

    result
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
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
