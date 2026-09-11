defmodule Mutare.ManifestTest do
  use ExUnit.Case, async: true
  import Mutare.Test.Metamutant

  alias Mutare.Manifest

  doctest Mutare.Manifest

  # The dispatch *variable* name is `Recorder.var_name/0`, never overridden by the dogfood
  # sandbox (only the `:persistent_term` key is), so `mutare_active` stays literal in the
  # assertions below — see transform_test's note. Each manifest is built with the name the
  # transform reported for the file (`dispatch_var`), which is what makes the salted cases
  # below readable at all.

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

      %{metamutant: meta, sites: [site], dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(src, mutators: [Mutare.Test.PoisonMutator])

      manifest = Manifest.from_source(meta, var)

      line = line_of(meta, "mutare_unbound_xyz")
      assert Manifest.ids_at_line(manifest, line) == [site.id]
    end

    test "a lifted-guard poison maps to its mutant, even though the bad code lives in a generated clause" do
      # Regression: the old line→id mapping matched only a selector clause's start
      # line, so a guard poison (whose code sits in a generated lifted clause, gated
      # by its id — not the public dispatcher) mapped to nothing → abort.
      %{metamutant: meta, sites: sites, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(@lifted_src, mutators: @lifted_mutators)

      manifest = Manifest.from_source(meta, var)

      poison = Enum.find(sites, &(&1.mutator == :poison))
      line = line_of(meta, "mutare_unbound_xyz")

      # the bad code sits in a generated lifted mutant clause, gated by its id —
      # lines away from the public dispatcher a naive start-line match would find
      assert meta |> String.split("\n") |> Enum.at(line - 1) =~
               ~r/:erlang\."=:="\(mutare_active, \d+\)/

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

      %{metamutant: meta, sites: [site], dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(src, mutators: [Mutare.Mutators.Arithmetic])

      manifest = Manifest.from_source(meta, var)

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

      %{metamutant: meta, sites: sites, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(src,
          mutators: [Mutare.Mutators.IntegerLiteral]
        )

      manifest = Manifest.from_source(meta, var)

      assert length(sites) > 1
      # The per-site read is hoisted, so the in-place selector's subject is the bound
      # `mutare_active` variable (`case mutare_active do`), not the inline persistent_term
      # read (which now sits on the prologue line above).
      case_line = line_of(meta, "case mutare_active do")

      assert Enum.sort(Manifest.ids_at_line(manifest, case_line)) ==
               Enum.sort(Enum.map(sites, & &1.id))
    end

    test "narrowest range wins: a precise clause line drops only that mutant, not the whole case" do
      %{metamutant: meta, sites: sites, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(@lifted_src, mutators: @lifted_mutators)

      manifest = Manifest.from_source(meta, var)

      poison = Enum.find(sites, &(&1.mutator == :poison))
      line = line_of(meta, "mutare_unbound_xyz")

      # the whole-case fallback also *contains* this line, but the specific def
      # range is narrower, so only the offending mutant is implicated
      assert Manifest.ids_at_line(manifest, line) == [poison.id]
      assert length(sites) > 1
    end

    test "a lifted-guard poison maps even when the source forces the dispatch var to be salted" do
      # Regression: `gate_id` used to hardcode the dispatch variable as `mutare_active`.
      # But when the *source* already uses that identifier, `Mutare.Transform.Names`
      # salts the generated one (`mutare_active_0`, …), so the gates read
      # `mutare_active_0 === <id>` and the hardcoded match found nothing → a lifted/
      # tupled poison was unmappable → abort. The transform now hands the salted name out
      # with the metamutant, and the manifest is built under it.
      salted_src = """
      defmodule Demo do
        def f(mutare_active) when mutare_active + 1 > 0, do: mutare_active
        def f(_), do: 0
      end
      """

      %{metamutant: meta, sites: sites, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(salted_src, mutators: @lifted_mutators)

      manifest = Manifest.from_source(meta, var)

      poison = Enum.find(sites, &(&1.mutator == :poison))
      line = line_of(meta, "mutare_unbound_xyz")

      # the scenario is real: the source's `mutare_active` forced the dispatch var to
      # be salted, so the gate is `mutare_active_<n> === <id>`, not bare `mutare_active`
      gate = meta |> String.split("\n") |> Enum.at(line - 1)
      assert gate =~ ~r/:erlang\."=:="\(mutare_active_\d+, \d+\)/
      refute gate =~ ~r/:erlang\."=:="\(mutare_active, \d+\)/

      assert Manifest.ids_at_line(manifest, line) == [poison.id]
    end

    test "an in-place poison maps even when the source itself reads the selector key into a var" do
      # A target file that binds the selector key into a variable of its own
      # (`foo = :persistent_term.get(...)`) is shape-identical to the generated prologue. A
      # manifest that *recovered* the dispatch name from the metamutant used to lock onto
      # that earlier binding (`:foo`) and then miss the real `case mutare_active do …`
      # selector, so a poison there mapped to `[]` and recovery aborted. The name is now
      # supplied, so the look-alike binding is never consulted.
      src = """
      defmodule Demo do
        @uses_pt foo = :persistent_term.get(:mutare_active, 0)

        def g(a, b), do: a + b
      end
      """

      %{metamutant: meta, sites: [site], dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(src, mutators: [Mutare.Test.PoisonMutator])

      manifest = Manifest.from_source(meta, var)

      # the user binding really does precede the generated prologue / hoisted selector
      assert line_of(meta, ~s(foo = :persistent_term.get)) <
               line_of(meta, "case mutare_active do")

      line = line_of(meta, "mutare_unbound_xyz")
      assert Manifest.ids_at_line(manifest, line) == [site.id]
    end

    test "an in-place poison maps even when the source binds a *reserved-family* dispatch name" do
      # The harder collision: the source binds the key into `mutare_active` itself. That
      # *forces* the real generated binding to be salted (`mutare_active_0 = …`, the hoisted
      # selector `case mutare_active_0 do`), while the user's `mutare_active` binding is both
      # family-named *and* earlier — any recovery by name or shape would lock onto it and miss
      # the salted selector. The supplied name is the salted one, so the selector is found.
      src = """
      defmodule Demo do
        @uses_pt mutare_active = :persistent_term.get(:mutare_active, 0)

        def g(a, b), do: a + b
      end
      """

      %{metamutant: meta, sites: [site], dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(src, mutators: [Mutare.Test.PoisonMutator])

      manifest = Manifest.from_source(meta, var)

      # the scenario is real: the source's `mutare_active` forced the generated binding
      # to be salted, so the hoisted selector reads the salted name, not bare `mutare_active`
      assert meta =~ "case mutare_active_0 do"
      refute meta =~ ~r/\bcase mutare_active do/

      assert line_of(meta, ~s(mutare_active = :persistent_term.get)) <
               line_of(meta, "case mutare_active_0 do")

      line = line_of(meta, "mutare_unbound_xyz")
      assert Manifest.ids_at_line(manifest, line) == [site.id]
    end

    test "a line with no generated code maps to nothing" do
      %{metamutant: meta, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(@lifted_src, mutators: @lifted_mutators)

      manifest = Manifest.from_source(meta, var)

      assert Manifest.ids_at_line(manifest, 9_999) == []
    end
  end

  describe "ids_at_line/2 — the tuple-the-scrutinee (case-clause) path" do
    @case_src """
    defmodule D do
      def classify(n) do
        case n do
          1 -> :one
          x when x > 5 -> :big
          _ -> :other
        end
      end
    end
    """

    test "a case-clause guard mutant's whole gated clause maps to exactly that id" do
      # A `case` clause pattern/guard mutation is delivered by tuple-the-scrutinee: the mutated
      # code lives in the clause *head* (`{mutare_active, x} when mutare_active === <id> and …`),
      # so the manifest records the whole clause range against that single id (the `pattern_mutant`
      # path), not a selector clause body.
      %{metamutant: meta, sites: sites, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(@case_src,
          mutators: [Mutare.Mutators.IntegerLiteral, Mutare.Mutators.Relational]
        )

      manifest = Manifest.from_source(meta, var)

      relaxed = Enum.find(sites, &(&1.mutator == :relational and &1.mutated_code == "x >= 5"))
      assert relaxed, "expected a relational guard mutant"

      # the mutated guard lives in a tupled, id-gated mutant clause head
      line = line_of(meta, "x >= 5")

      assert meta |> String.split("\n") |> Enum.at(line - 1) =~
               ~r/:erlang\."=:="\(mutare_active, \d+\)/

      assert Manifest.ids_at_line(manifest, line) == [relaxed.id]
    end

    test "the whole tupled `case` is the coarse fallback for every clause-mutant id it hosts" do
      %{metamutant: meta, sites: sites, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(@case_src,
          mutators: [Mutare.Mutators.IntegerLiteral]
        )

      manifest = Manifest.from_source(meta, var)

      clause_ids = sites |> Enum.map(& &1.id) |> Enum.sort()
      case_line = line_of(meta, selector_tuple() <> " n}")

      assert Enum.sort(Manifest.ids_at_line(manifest, case_line)) == clause_ids
    end
  end
end
