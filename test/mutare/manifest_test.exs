defmodule Mutare.ManifestTest do
  use ExUnit.Case, async: true

  alias Mutare.{Manifest, Selector}

  doctest Mutare.Manifest

  # The metamutant's `:persistent_term` key is `Selector.key/0` resolved at *runtime*
  # (`:mutare_active` normally; the private suite key when these tests themselves run
  # inside a dogfood sandbox). The subject recognisers (`Mutare.Metamutant.subject?/2`)
  # read the same `Selector.key/0`, so a hand-crafted fixture must use it too rather than
  # a hardcoded `:mutare_active` — otherwise the key mismatches under self-hosting and the
  # subject goes unrecognised. (The dispatch *variable* name is `Recorder.var_name/0`,
  # never overridden, so `mutare_active` stays literal — see transform_test's note.)
  defp pt_key, do: inspect(Selector.key())

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

      {meta, [site], _next} =
        Mutare.Transform.transform_string_with_sites(src, mutators: [Mutare.Test.PoisonMutator])

      manifest = Manifest.from_source(meta)

      line = line_of(meta, "mutare_unbound_xyz")
      assert Manifest.ids_at_line(manifest, line) == [site.id]
    end

    test "a lifted-guard poison maps to its mutant, even though the bad code lives in a generated clause" do
      # Regression: the old line→id mapping matched only a selector clause's start
      # line, so a guard poison (whose code sits in a generated lifted clause, gated
      # by its id — not the public dispatcher) mapped to nothing → abort.
      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(@lifted_src, mutators: @lifted_mutators)

      manifest = Manifest.from_source(meta)

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

      {meta, [site], _next} =
        Mutare.Transform.transform_string_with_sites(src, mutators: [Mutare.Mutators.Arithmetic])

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

      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(src,
          mutators: [Mutare.Mutators.IntegerLiteral]
        )

      manifest = Manifest.from_source(meta)

      assert length(sites) > 1
      # The per-site read is hoisted, so the in-place selector's subject is the bound
      # `mutare_active` variable (`case mutare_active do`), not the inline persistent_term
      # read (which now sits on the prologue line above).
      case_line = line_of(meta, "case mutare_active do")

      assert Enum.sort(Manifest.ids_at_line(manifest, case_line)) ==
               Enum.sort(Enum.map(sites, & &1.id))
    end

    test "narrowest range wins: a precise clause line drops only that mutant, not the whole case" do
      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(@lifted_src, mutators: @lifted_mutators)

      manifest = Manifest.from_source(meta)

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
      # tupled poison was unmappable → abort. The manifest now recovers the salted name.
      salted_src = """
      defmodule Demo do
        def f(mutare_active) when mutare_active + 1 > 0, do: mutare_active
        def f(_), do: 0
      end
      """

      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(salted_src, mutators: @lifted_mutators)

      manifest = Manifest.from_source(meta)

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
      # Regression: `active_var/1` recovers the dispatch variable from the first
      # `<var> = :persistent_term.get(<key>, 0)` it sees. A target file that binds the
      # *same* key into a variable of its own (`foo = :persistent_term.get(...)`) is
      # shape-identical to the generated prologue, so an earlier such binding made the
      # walk recover `:foo` — and then fail to recognise the real `case mutare_active
      # do …` hoisted selector, leaving the in-place mutant with no region. A poison
      # there mapped to `[]` and recovery aborted. `active_var/1` now keeps only names
      # in the generated dispatch-variable family, skipping the user binding.
      src = """
      defmodule Demo do
        @uses_pt foo = :persistent_term.get(:mutare_active, 0)

        def g(a, b), do: a + b
      end
      """

      {meta, [site], _next} =
        Mutare.Transform.transform_string_with_sites(src, mutators: [Mutare.Test.PoisonMutator])

      manifest = Manifest.from_source(meta)

      # the user binding really does precede the generated prologue / hoisted selector
      assert line_of(meta, ~s(foo = :persistent_term.get)) <
               line_of(meta, "case mutare_active do")

      line = line_of(meta, "mutare_unbound_xyz")
      assert Manifest.ids_at_line(manifest, line) == [site.id]
    end

    test "an in-place poison maps even when the source binds a *reserved-family* dispatch name" do
      # The harder collision: the source binds the key into `mutare_active` itself — a
      # reserved-family name. That *forces* the real generated binding to be salted
      # (`mutare_active_0 = …`, the hoisted selector `case mutare_active_0 do`), yet the
      # user's `mutare_active` binding is both family-named *and* earlier — so a name
      # filter alone still locks onto it and misses the salted selector. The dispatch
      # name is instead recovered from the unforgeable coverage record (`<var> == 0 and
      # :persistent_term.get(:mutare_track, false) and …`), which names the real salted
      # variable.
      src = """
      defmodule Demo do
        @uses_pt mutare_active = :persistent_term.get(:mutare_active, 0)

        def g(a, b), do: a + b
      end
      """

      {meta, [site], _next} =
        Mutare.Transform.transform_string_with_sites(src, mutators: [Mutare.Test.PoisonMutator])

      manifest = Manifest.from_source(meta)

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
      {meta, _sites, _next} =
        Mutare.Transform.transform_string_with_sites(@lifted_src, mutators: @lifted_mutators)

      manifest = Manifest.from_source(meta)

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
      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(@case_src,
          mutators: [Mutare.Mutators.IntegerLiteral, Mutare.Mutators.Relational]
        )

      manifest = Manifest.from_source(meta)

      relaxed = Enum.find(sites, &(&1.mutator == :relational and &1.mutated_code == "x >= 5"))
      assert relaxed, "expected a relational guard mutant"

      # the mutated guard lives in a tupled, id-gated mutant clause head
      line = line_of(meta, "x >= 5")

      assert meta |> String.split("\n") |> Enum.at(line - 1) =~
               ~r/:erlang\."=:="\(mutare_active, \d+\)/

      assert Manifest.ids_at_line(manifest, line) == [relaxed.id]
    end

    test "the whole tupled `case` is the coarse fallback for every clause-mutant id it hosts" do
      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(@case_src,
          mutators: [Mutare.Mutators.IntegerLiteral]
        )

      manifest = Manifest.from_source(meta)

      clause_ids = sites |> Enum.map(& &1.id) |> Enum.sort()
      case_line = line_of(meta, "case (case {mutare_active, n}")

      assert Enum.sort(Manifest.ids_at_line(manifest, case_line)) == clause_ids
    end
  end

  describe "active_var/1 fallbacks — recovering the dispatch name without a coverage record" do
    # A real metamutant always carries a coverage record, so `active_var/1` recovers the dispatch
    # name from it. These hand-crafted (record-less) metamutant strings exercise the *fallback*
    # anchors `from_source` keeps for the theoretical shape that lacks one.

    test "recovers the name from a `<var> = :persistent_term.get` binding (the `=` anchor)" do
      src = """
      defmodule D do
        def f(_x) do
          mutare_active = :persistent_term.get(#{pt_key()}, 0)

          case mutare_active do
            1 -> :mutated
            mutare_active -> :original
          end
        end
      end
      """

      manifest = Manifest.from_source(src)

      line = line_of(src, "1 -> :mutated")
      assert Manifest.ids_at_line(manifest, line) == [1]
    end

    test "recovers the name from a tupled-`case` clause pattern (the `:case` anchor)" do
      # Inline-read first element so the var-less `pattern_subject?` recognises the subject, and
      # no `=` binding precedes it — forcing recovery through the `:case` anchor / `clause_tuple_var`.
      src = """
      defmodule D do
        def f(_x) do
          case {:persistent_term.get(#{pt_key()}, 0), _x} do
            {mutare_active, 1} when :erlang."=:="(mutare_active, 1) -> :a
            {mutare_active, _} -> :b
          end
        end
      end
      """

      manifest = Manifest.from_source(src)

      line = line_of(src, ~s|:erlang."=:="(mutare_active, 1)|)
      assert Manifest.ids_at_line(manifest, line) == [1]
    end

    test "falls back to the canonical name when there is neither a record nor an anchor" do
      # A module with no mutations has no selectors at all: no record, no anchor — so `active_var/1`
      # returns the canonical `Recorder.var_name()` and the walk yields no regions.
      manifest = Manifest.from_source("defmodule D do\n  def f, do: 1\nend\n")
      assert manifest.regions == []
    end
  end
end
