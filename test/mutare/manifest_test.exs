defmodule Mutare.ManifestTest do
  use ExUnit.Case, async: true

  alias Mutare.Manifest

  # A guard whose `+` poisons (→ unbound var, won't compile) plus relational
  # swaps and clause drops — exercises a lifted mutant whose bad code lives in a
  # generated private `defp`, lines away from its dispatcher clause.
  @lifted_src """
  defmodule Demo do
    def f(a) when a + 1 > 0, do: a
    def f(_), do: 0
  end
  """
  @lifted_mutators [Mutare.Test.PoisonMutator, Mutare.Mutators.Relational]

  # Line of the rendered metamutant containing `needle` (1-based).
  defp line_of(meta, needle) do
    meta
    |> String.split("\n")
    |> Enum.find_index(&(&1 =~ needle))
    |> Kernel.+(1)
  end

  describe "ids_at_line/2 — mapping a compile error to its mutant" do
    test "an in-place poison maps to the mutant at that line" do
      src = "defmodule P do\n  def f(a, b), do: a + b\nend\n"
      {meta, [site], _next} = Mutare.transform_string(src, mutators: [Mutare.Test.PoisonMutator])
      manifest = Manifest.from_source(meta)

      line = line_of(meta, "mutare_unbound_xyz")
      assert Manifest.ids_at_line(manifest, line) == [site.id]
    end

    test "a lifted-guard poison maps to its mutant, even though the bad code lives in a generated clause" do
      # Regression: the old line→id mapping matched only a selector clause's start
      # line, so a guard poison (whose code sits in a generated lifted clause, gated
      # by its id — not the public dispatcher) mapped to nothing → abort.
      {meta, sites, _next} = Mutare.transform_string(@lifted_src, mutators: @lifted_mutators)
      manifest = Manifest.from_source(meta)

      poison = Enum.find(sites, &(&1.mutator == :poison))
      line = line_of(meta, "mutare_unbound_xyz")

      # the bad code sits in a generated lifted mutant clause, gated by its id —
      # lines away from the public dispatcher a naive start-line match would find
      assert meta |> String.split("\n") |> Enum.at(line - 1) =~ ~r/mutare_active === \d+/
      assert Manifest.ids_at_line(manifest, line) == [poison.id]
    end

    test "a multiline mutant body resolves on any of its lines, not just the first" do
      src = """
      defmodule D do
        def f(a, b) do
          a +
            b
        end
      end
      """

      {meta, [site], _next} = Mutare.transform_string(src, mutators: [Mutare.Mutators.Arithmetic])
      manifest = Manifest.from_source(meta)

      # the mutated body spans more than one line, and its last line still maps back
      region = Enum.find(manifest.regions, &(&1.ids == [site.id] and &1.hi > &1.lo))
      assert region, "expected a multiline body region for the mutant"
      assert Manifest.ids_at_line(manifest, region.hi) == [site.id]
      assert Manifest.ids_at_line(manifest, region.lo) == [site.id]
    end

    test "a structural error at the surrounding in-place case maps to every mutant it hosts" do
      # One node with several mutations (an integer → n+1, n-1, 0) shares a single
      # in-place selector `case`. An error the compiler points at the `case` itself
      # (not one clause body) maps to *every* id the case hosts — the coarse fallback
      # that still recovers the build. (Lifted mutants are each their own gated
      # clause now, so they map precisely; the coarse net is the in-place case.)
      src = "defmodule D do\n  def f, do: 5\nend\n"
      {meta, sites, _next} = Mutare.transform_string(src, mutators: [Mutare.Mutators.Literal])
      manifest = Manifest.from_source(meta)

      assert length(sites) > 1
      case_line = line_of(meta, "persistent_term.get")

      assert Enum.sort(Manifest.ids_at_line(manifest, case_line)) ==
               Enum.sort(Enum.map(sites, & &1.id))
    end

    test "narrowest range wins: a precise clause line drops only that mutant, not the whole case" do
      {meta, sites, _next} = Mutare.transform_string(@lifted_src, mutators: @lifted_mutators)
      manifest = Manifest.from_source(meta)

      poison = Enum.find(sites, &(&1.mutator == :poison))
      line = line_of(meta, "mutare_unbound_xyz")

      # the whole-case fallback also *contains* this line, but the specific def
      # range is narrower, so only the offending mutant is implicated
      assert Manifest.ids_at_line(manifest, line) == [poison.id]
      assert length(sites) > 1
    end

    test "a line with no generated code maps to nothing" do
      {meta, _sites, _next} = Mutare.transform_string(@lifted_src, mutators: @lifted_mutators)
      manifest = Manifest.from_source(meta)

      assert Manifest.ids_at_line(manifest, 9_999) == []
    end
  end
end
