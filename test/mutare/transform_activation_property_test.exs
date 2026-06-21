defmodule Mutare.TransformActivationPropertyTest do
  @moduledoc """
  The **per-mutant** runtime property: activating any single mutant runs cleanly and stays
  **isolated** — it perturbs at most one function.

  The other runtime property (`transform_baseline_property_test.exs`) only exercises mutant 0 —
  it proves the baseline metamutant matches the original, but never activates a *real* mutant.
  Yet the tool's whole value is the non-zero mutants, and every subtle rewrite that delivers one
  — the lifted dispatcher, tuple-the-scrutinee `case`, the pipe-hoisting closure, the
  whole-construct selector, default-arg forwarding — only fires when its id is the active one.
  A bug there (a misdispatch, a gate that matches the wrong id, a salting collision, a leak
  across functions) compiles cleanly and matches at baseline, so it shows up *here* and nowhere
  else.

  Because the metamutant embeds **every** mutant behind the `:persistent_term` selector, this
  needs only the *one* compile the bet is built on: compile the metamutant once, probe it at
  baseline, then flip the selector to each recorded mutant id in turn and re-probe — no
  recompilation. For each mutant we assert the invariant that holds by construction for a
  *single localized* rewrite:

      activating mutant `k` changes the observable behaviour of **at most one** function.

  A mutant lives in exactly one function (the generator emits no inter-function calls, no
  recursion, no shared mutable state), so every *other* function must run its original path —
  its selectors fall through, the active id matching none of its sites. A second perturbed
  function means the mutation leaked out of its function: cross-function interference the
  baseline can't see. (Zero changed functions is fine — an equivalent mutant, or one the probe
  inputs never reach.) Functions are grouped by **name**: a generated group is one liftable
  function, so a default-arg mutant that moves both `f/1` and `f/2` is still one function.

  Blame is kept on the transform the same way the compile/baseline properties keep it: the
  metamutant must compile (the compile property guards that), so a failure here re-checks that
  the *original* compiled, distinguishing "the transform broke a compiling input" from a
  generator bug.
  """
  # Compiles a module per case, purges it, captures :stderr globally, and flips the global
  # `:persistent_term` selector across every mutant id — must be serial.
  use ExUnit.Case, async: false
  use PropCheck

  alias Mutare.{PropertyProbe, Selector}
  alias Mutare.TransformPropertyGenerators, as: Gen

  # One compile per case (the metamutant) plus a probe sweep over every mutant id — cheaper per
  # case than the baseline property's two compiles, so the budget can be a touch larger. The
  # deepened generator keeps coverage high per case. Raise locally for a longer soak.
  @numtests 40
  @moduletag timeout: 300_000
  @moduletag :property

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  property "activating any single mutant perturbs at most one function", numtests: @numtests do
    forall module_ast <- Gen.module_gen() do
      source = Macro.to_string(module_ast)
      {metamutant, sites, _next_id} = Mutare.transform_string(source, file: "prop.ex")
      ids = Enum.map(sites, & &1.id)
      Selector.put(Selector.baseline())

      case sweep(metamutant, module_ast, ids) do
        {:error, meta_reason} ->
          report_failure(blame(source), meta_reason, source, metamutant)
          false

        {:ok, {specs, baseline, per_mutant}} ->
          isolated?(specs, baseline, per_mutant, source, metamutant)
      end
    end
  end

  # Compile the metamutant once, derive the probe specs, probe at baseline, then probe again at
  # each mutant id by flipping the selector (no recompile). Returns `{:ok, {specs, baseline,
  # [{id, outcomes}]}}` or `{:error, exception}` if the metamutant did not compile.
  defp sweep(metamutant, module_ast, ids) do
    PropertyProbe.with_compiled(metamutant, fn ->
      specs = PropertyProbe.specs(module_ast)

      Selector.put(Selector.baseline())
      baseline = Enum.map(specs, &PropertyProbe.probe/1)

      per_mutant =
        Enum.map(ids, fn id ->
          Selector.put(id)
          {id, Enum.map(specs, &PropertyProbe.probe/1)}
        end)

      Selector.put(Selector.baseline())
      {specs, baseline, per_mutant}
    end)
  end

  # The first mutant (if any) whose activation perturbs more than one function, else `nil`.
  defp isolated?(specs, baseline, per_mutant, source, metamutant) do
    violation =
      Enum.find_value(per_mutant, fn {id, outcomes} ->
        changed = changed_functions(specs, baseline, outcomes)
        if length(changed) > 1, do: {id, changed}, else: nil
      end)

    case violation do
      nil ->
        true

      {id, changed} ->
        report_failure(
          "mutant #{id} perturbed #{length(changed)} functions (expected at most one)",
          %{mutant: id, functions: changed},
          source,
          metamutant
        )

        false
    end
  end

  # The distinct function *names* whose outcome changed between baseline and this mutant. A
  # generated group shares one name across its clauses/arities, so a default-arg mutant touching
  # `f/1` and `f/2` collapses to the single function `f` — exactly one perturbed function.
  defp changed_functions(specs, baseline, mutant) do
    [specs, baseline, mutant]
    |> Enum.zip()
    |> Enum.filter(fn {_spec, b, m} -> b != m end)
    |> Enum.map(fn {{name, _args}, _b, _m} -> name end)
    |> Enum.uniq()
  end

  # On a metamutant compile failure, attribute blame: the metamutant must compile (the compile
  # property guards it), so the fault is the transform's unless the *original* did not compile.
  defp blame(source) do
    case PropertyProbe.with_compiled(source, fn -> :ok end) do
      {:ok, _} -> "metamutant did not compile (the transform broke a compiling input)"
      {:error, _} -> "generated input did not compile (generator bug)"
    end
  end

  # Surface the seed and offending output on a counterexample, actionable straight from the log
  # (PropCheck also records the shrunk seed in its `.ctex` file).
  defp report_failure(what, reason, source, metamutant) do
    IO.puts("""

    ACTIVATION PROPERTY FAILURE: #{what}: #{inspect(reason)}
    === source ===
    #{source}
    === metamutant ===
    #{metamutant}
    """)
  end
end
