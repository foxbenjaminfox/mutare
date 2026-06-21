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

  Serial + lower `numtests` than the parse property: each case compiles a BEAM module
  (and captures the metamutant's legitimate warnings — unreachable clauses from
  wildcard-broadening, unused bindings), which is both stateful (the code server) and an
  order of magnitude slower than a parse.
  """
  # Compiles modules, purges them, and captures :stderr globally — must be serial.
  use ExUnit.Case, async: false
  use PropCheck

  alias Mutare.TransformPropertyGenerators, as: Gen

  # Compiling a BEAM module per case is ~an order of magnitude slower than a parse, so
  # the budget is smaller than the parse property's; the rich generator keeps coverage
  # high per case. Raise locally for a longer soak.
  @numtests 50
  @moduletag timeout: 300_000
  @moduletag :property

  property "the metamutant always compiles", numtests: @numtests do
    forall module_ast <- Gen.module_gen() do
      source = Macro.to_string(module_ast)
      {metamutant, _sites, _next_id} = Mutare.transform_string(source, file: "prop.ex")

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

  # Compile a source string, swallowing its (legitimate) warnings and purging every
  # module it defines so the fixed `Prop` name doesn't accumulate or clash across runs.
  # Returns `:ok` or `{:error, exception}`.
  defp compile_quietly(source) do
    {result, _io} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        try do
          source
          |> Code.compile_string()
          |> Enum.each(fn {module, _binary} -> purge(module) end)

          :ok
        rescue
          e -> {:error, e}
        end
      end)

    result
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
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
