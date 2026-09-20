defmodule Mutare.TransformRoutedPipePropertyTest do
  @moduledoc """
  **Desugaring commutes with the transform.** `left |> stage(args)` is sugar for
  `stage(left, args)`, and a stage under a positional call route is read as that direct call
  (`Mutare.Transform.WrittenPipe`). So a module whose routed calls are all written piped and
  the same module with them all written directly are one program to Mutare, and must get the
  same mutants:

      for every module `m`, the programs the sites of `respell(m, :piped)` promise are the
      programs the sites of `respell(m, :direct)` promise.

  "The program a site promises" is the report's own contract (`Mutare.Test.SourcePatch`): the
  source patched at `site.range` with `site.mutated_code` (parenthesized — see `promise/2`).
  Both sides are parsed, every `|>`
  desugared with `Macro.pipe/3`, and metadata dropped, so the comparison is blind to spelling,
  to the span a site chose (a stage, or the whole pipe), and to parentheses — and sees only
  which programs the mutants are.

  What it catches: a reader that takes a marked stage as written lands each treatment one
  argument late, which mutates the generator's `:raw` bait in the piped spelling only
  (`Mutare.Transform.Meta.routing/1` now raises there, so such a reader fails here as a crash);
  a range or a stage attribution that patches the wrong span; a Site rendered in a spelling
  that is not the program that ran. Parse-only, so it needs no compile and no serial `Prop`.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.Test.SourcePatch
  alias Mutare.TransformPropertyGenerators, as: Gen

  # Each case patches and parses the module once per site, per spelling — the cost of a compile
  # soak's case, so it takes that soak's budget.
  @numtests 50
  @max_size 16
  @moduletag timeout: 600_000
  @moduletag :property

  property "a module's piped and direct spellings get the same mutants",
    numtests: @numtests,
    max_size: @max_size do
    forall module_ast <- Gen.module_gen() do
      piped_source = module_ast |> Gen.respell(:piped) |> Macro.to_string()
      direct_source = module_ast |> Gen.respell(:direct) |> Macro.to_string()

      # The premise, checked: the two sources are one program. `Macro.to_string/1` does not
      # always round-trip a generated AST — `!(if … end) |> f()` is rendered `!if … end |> f()`,
      # which parses as `!(if … end |> f())` — and such a case says nothing about Mutare.
      implies normalize(piped_source) == normalize(direct_source) do
        piped = promised(piped_source)
        direct = promised(direct_source)

        if piped == direct do
          true
        else
          report_failure(module_ast, piped, direct)
          false
        end
      end
    end
  end

  test "the generator reaches both deliveries of a rewritten stage" do
    metamutants =
      for seed <- 1..25,
          {:ok, module_ast} = PropCheck.produce(Gen.module_gen(), seed),
          source = module_ast |> Gen.respell(:piped) |> Macro.to_string(),
          do:
            Mutare.Transform.transform_string_with_sites(source, Gen.transform_opts()).metamutant

    # Rewritten: the routed stage is emitted as the direct call.
    assert Enum.any?(metamutants, &(&1 =~ ~r/RoutedSoak\.keep\([^|]*1 < 2/s))
    # Bound: a `keep/3` stage's selector closes over its piped value, under the user's `|>`.
    assert Enum.any?(metamutants, &(&1 =~ ~r/RoutedSoak\.keep\(\s*mutare_piped\w*,/))
    # Plain: a `:lazy_expression` position is never bound.
    assert Enum.any?(metamutants, &(&1 =~ "RoutedSoak.pick("))
    refute Enum.any?(metamutants, &(&1 =~ ~r/RoutedSoak\.pick\(\s*mutare_piped/))
  end

  # The programs `source`'s sites promise, normalized and sorted — a multiset, so a mutant
  # one spelling produces twice is not hidden by the other producing it once.
  defp promised(source) do
    %{sites: sites} = Mutare.Transform.transform_string_with_sites(source, Gen.transform_opts())

    sites
    |> Enum.map(fn site -> {site.mutator, promise(source, site)} end)
    |> Enum.sort()
  end

  # The program a site promises, spelling-blind. The replacement is patched in **parenthesized**
  # where that parses: a pipe's left side is an operator context and a call's argument is not,
  # so a replacement that binds looser than what it replaced (`!(a == 0)` → `a == 0`, patched to
  # `a == 0 |> f()`) reads differently in the two spellings. That is a defect in how a Site
  # renders its replacement — NOTES "A replacement is rendered without its context" — and not
  # what this property is about, which is *which* node a site names and what it becomes. A patch
  # that parses neither way (a whole clause, the same NOTES entry's `--0.25`) is compared by
  # its replacement alone.
  defp promise(source, site) do
    with :error <- normalize(patch(source, site, &"(#{&1})")),
         :error <- normalize(patch(source, site, & &1)),
         :error <- normalize(site.mutated_code) do
      {:unparseable, site.mutated_code}
    else
      {:ok, program} -> program
    end
  end

  defp patch(source, %{operation: :delete} = site, _wrap), do: SourcePatch.patch(source, site)

  defp patch(source, site, wrap),
    do: SourcePatch.patch(source, %{site | mutated_code: wrap.(site.mutated_code)})

  defp normalize(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> {:ok, ast |> Macro.postwalk(&desugar/1) |> Macro.to_string()}
      {:error, _reason} -> :error
    end
  end

  defp desugar({:|>, _meta, [left, right]} = pipe) do
    Macro.pipe(left, right, 0)
  rescue
    # A mutant may leave a stage nothing can be piped into; both spellings then keep it.
    ArgumentError -> strip(pipe)
  end

  defp desugar(node), do: strip(node)

  defp strip(node), do: Macro.update_meta(node, fn _meta -> [] end)

  defp report_failure(module_ast, piped, direct) do
    IO.puts("""

    ROUTED PIPE PROPERTY FAILURE: the two spellings got different mutants.
    === module (as generated) ===
    #{Macro.to_string(module_ast)}
    === only the piped spelling promises ===
    #{render(piped -- direct)}
    === only the direct spelling promises ===
    #{render(direct -- piped)}
    """)
  end

  defp render(programs) do
    Enum.map_join(programs, "\n---\n", fn
      {mutator, {:unparseable, mutated_code}} ->
        "#{mutator}: UNPARSEABLE replacement #{inspect(mutated_code)}"

      {mutator, program} ->
        "#{mutator}:\n#{program}"
    end)
  end
end
