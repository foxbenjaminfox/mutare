defmodule Mutare.TransformCompilePropertyTest do
  @moduledoc """
  The strongest property the tool can be held to: **the metamutant compiles**.

  `transform_property_test.exs` checks the metamutant *parses* — but parsing is weaker
  than the bet. The negative-magnitude-in-a-match bug was exactly a mutant that parsed
  (`-(-0.5)`) yet wouldn't compile (`:erlang.-/1` inside a pattern). The tool compiles
  the metamutant **once**, so an un-compilable mutant anywhere sinks the whole run; this
  property exercises that directly over randomly generated modules:

      for every compilable module `m`, `transform_string(m)` produces source that
      *compiles* (not merely parses).

  Blame is kept on the transform: a generated module is compilable by construction, but
  if one isn't (a generator bug), compiling the *original* on failure distinguishes
  "generator produced non-compiling input" from "the transform broke a compiling input"
  — so a green property is a real statement about the transform.

  Lower `numtests` than the parse property: each case compiles a BEAM module (and captures
  the metamutant's legitimate warnings — unreachable clauses from wildcard-broadening,
  unused bindings), an order of magnitude slower than a parse. Each compile nests the
  generator's `Prop` under a unique wrapper, so the soak runs beside the others.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.TransformPropertyGenerators, as: Gen

  # Compiling a BEAM module per case is ~an order of magnitude slower than a parse, so
  # the budget is smaller than the parse property's; the rich generator keeps coverage
  # high per case. Raise locally for a longer soak.
  @numtests 50
  # Cap proper's size — `expr_gen` already bounds depth (`min(size, 4)`), so larger sizes only
  # inflate leaf/function counts, and the uncapped high-size tail tripped the timeout under load
  # (see `transform_property_test.exs` for the full rationale).
  @max_size 16
  # Headroom over the per-property budget for a slow-but-correct soak under load
  # (see `transform_property_test.exs`).
  @moduletag timeout: 600_000
  @moduletag :property

  property "the metamutant always compiles", numtests: @numtests, max_size: @max_size do
    forall module_ast <- Gen.module_gen() do
      source = Macro.to_string(module_ast)

      %{metamutant: metamutant} =
        Mutare.Transform.transform_string_with_sites(source, Gen.transform_opts())

      case compile_quietly(metamutant) do
        :ok ->
          true

        {:error, meta_reason} ->
          # Did the *input* compile? If not, this is a generator bug, not the transform's.
          {whose, reason} =
            case compile_quietly(source) do
              :ok -> {"the transform broke a compiling input", meta_reason}
              {:error, src_reason} -> {"generated input did not compile", src_reason}
            end

          report_failure(whose, reason, source, metamutant)
          false
      end
    end
  end

  # Compile a source string under a unique wrapper, swallowing its (legitimate) warnings.
  # Returns `:ok` or `{:error, exception}`.
  defp compile_quietly(source) do
    case Mutare.PropertyProbe.with_compiled(source, fn _module -> :ok end) do
      {:ok, :ok} -> :ok
      {:error, e} -> {:error, e}
    end
  end

  defp report_failure(whose, reason, source, metamutant) do
    IO.puts("""

    COMPILE PROPERTY FAILURE (#{whose}): #{Exception.message(reason)}
    === source ===
    #{source}
    === metamutant ===
    #{metamutant}
    """)
  end
end
