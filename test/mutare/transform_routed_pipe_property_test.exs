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
  source patched at `site.range` with `site.mutated_code`. Both sides are parsed, every `|>`
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

        if piped == direct and not Enum.any?(piped ++ direct, &match?({_, {:unparseable, _}}, &1)) do
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

    # The `:raw` slot reaches the metamutant as written.
    assert Enum.any?(metamutants, &(&1 =~ ~r/RoutedSoak\.keep\([^|]*1 < 2/s))
    # Bound: a `keep/3` stage's selector closes over its piped value, under the user's `|>`.
    assert Enum.any?(metamutants, &(&1 =~ ~r/mutare_piped\w*\s*\|> [\w.]*RoutedSoak\.keep\(/))
    # Plain: a `:lazy_expression` position is never bound.
    assert Enum.any?(metamutants, &(&1 =~ "RoutedSoak.pick("))
    refute Enum.any?(metamutants, &(&1 =~ ~r/mutare_piped\w*\s*\|> [\w.]*RoutedSoak\.pick\(/))
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

  # The program a site promises, spelling-blind: the source patched at the site's range, as the
  # report patches it. A patch that does not parse is a failure in its own right — it is the
  # diff a user would be shown — with one known exception (`unrecorded_parentheses?/2`).
  defp promise(source, site) do
    patched = SourcePatch.patch(source, site)

    case normalize(patched) do
      {:ok, program} ->
        program

      :error ->
        if unrecorded_parentheses?(source, site), do: :known_limit, else: {:unparseable, patched}
    end
  end

  # Elixir's parser records no `:parens` meta for a parenthesized *unary* operand — `not (!a)`
  # parses exactly as `not !a` would — so no range can be told to cover that `)`
  # (NOTES "A replacement is rendered without its context"). The symptom is unmistakable: the
  # text the range covers has an unclosed parenthesis.
  defp unrecorded_parentheses?(source, %{range: range}) do
    covered =
      source |> Sourceror.patch_string([%{range: range, change: "\u0000"}]) |> covered_by(source)

    count(covered, "(") > count(covered, ")")
  end

  # What a patch replaced: the source minus the prefix and suffix it shares with the patched text.
  defp covered_by(patched, source) do
    [prefix, suffix] = String.split(patched, "\u0000", parts: 2)
    source |> String.replace_prefix(prefix, "") |> String.replace_suffix(suffix, "")
  end

  defp count(text, part), do: text |> String.split(part) |> length() |> Kernel.-(1)

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

    ROUTED PIPE PROPERTY FAILURE: the two spellings' mutants differ, or a patch does not parse.
    === module (as generated) ===
    #{Macro.to_string(module_ast)}
    === only the piped spelling promises ===
    #{render(piped -- direct)}
    === only the direct spelling promises ===
    #{render(direct -- piped)}
    === patches that do not parse ===
    #{render(Enum.filter(piped ++ direct, &match?({_, {:unparseable, _}}, &1)))}
    """)
  end

  defp render(programs) do
    Enum.map_join(programs, "\n---\n", fn
      {mutator, {:unparseable, patched}} ->
        "#{mutator}: UNPARSEABLE\n#{patched}"

      {mutator, program} ->
        "#{mutator}:\n#{program}"
    end)
  end
end
