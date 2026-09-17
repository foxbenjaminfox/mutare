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

    test "tupled clause attribution survives a bound coverage gate" do
      %{metamutant: source, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(@case_src,
          mutators: [Mutare.Mutators.IntegerLiteral, Mutare.Mutators.Relational]
        )

      # Compare attribution under the same renderer on both sides. Only the gate
      # changes; the payload and tuple input/output flow remain intact.
      ast = Code.string_to_quoted!(source)

      changed =
        Macro.postwalk(ast, fn node ->
          if Mutare.Coverage.Recorder.record?(node) do
            {:case, meta, [_gate, clauses]} = node
            {:case, meta, [{:mutare_tracking, [], nil}, clauses]}
          else
            node
          end
        end)

      before_source = Macro.to_string(ast)
      after_source = Macro.to_string(changed)
      before = Manifest.from_source(before_source, var)
      after_manifest = Manifest.from_source(after_source, var)
      assert Enum.map(before.regions, & &1.ids) == Enum.map(after_manifest.regions, & &1.ids)

      assert Manifest.ids_at_line(before, line_of(before_source, "x >= 5")) ==
               Manifest.ids_at_line(after_manifest, line_of(after_source, "x >= 5"))
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

  describe "mentions — every generated reference to a mutant id" do
    defp mentions(source, mutators) do
      %{metamutant: meta, sites: sites, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(source, mutators: mutators)

      {Manifest.from_source(meta, var).mentions, sites}
    end

    defp ids(mentions, kind),
      do: for(%{kind: ^kind, id: id, within: nil} <- mentions, do: id) |> Enum.sort()

    test "an in-place selector mentions each mutant as a branch and in a coverage record" do
      {mentions, sites} =
        mentions("defmodule P do\n  def f(a, b), do: a + b\nend\n", [:arithmetic])

      site_ids = sites |> Enum.map(& &1.id) |> Enum.sort()
      assert [_ | _] = site_ids
      assert ids(mentions, :branch) == site_ids
      assert ids(mentions, :record) == site_ids
      assert ids(mentions, :exclusion) == []
    end

    test "a dropped lifted clause is mentioned only by its original's exclusion" do
      {mentions, sites} =
        mentions("defmodule D do\n  def f(0), do: :zero\n  def f(n), do: n\nend\n", [
          :clause_drop
        ])

      drop_ids = for %{mutator: :clause_drop, id: id} <- sites, do: id
      assert [_, _] = drop_ids
      assert ids(mentions, :exclusion) == drop_ids
      assert ids(mentions, :branch) == []
    end

    test "an exclusion written as a range names every id in it" do
      # The first clause's guard mutants and its drop, at least seven consecutive ids, all
      # exclude its original: one run, written as a range.
      source = """
      defmodule R do
        def f(a) when a > 1 and a < 9, do: a
        def f(_), do: 0
      end
      """

      %{metamutant: meta, sites: sites, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [:relational, :integer, :clause_drop]
        )

      assert meta =~ ~r/:erlang\.<\(mutare_active, \d+\)/

      first_clause = for %{line: 2, id: id} <- sites, do: id
      assert length(first_clause) >= 7

      exclusions =
        for %{kind: :exclusion, id: id} <- Manifest.from_source(meta, var).mentions, do: id

      assert first_clause -- exclusions == []
    end

    test "mentions follow the metamutant's text order" do
      # A tuple's halves, hoisted pipe stages (ids assigned out of text order), and a call whose
      # callee and argument both hold mutants.
      source = """
      defmodule T do
        def f(a, b), do: {a + 1, b - 1}
        def g(xs), do: xs |> Enum.sort() |> Enum.take(2)
        def h, do: (fn x -> x + 1 end).(2)
      end
      """

      %{metamutant: meta, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [:arithmetic, :collection_arity, :integer]
        )

      in_text = for [_, id] <- Regex.scan(~r/^\s*(\d+) ->/m, meta), do: String.to_integer(id)
      branches = for %{kind: :branch, id: id} <- Manifest.from_source(meta, var).mentions, do: id

      assert branches == in_text
      assert branches != Enum.sort(branches)
    end

    test "a guard sequence mentions each gated alternative and each exclusion once" do
      # The second generator's guard and the `else` clause's are both sequences; the originals
      # carry the exclusions, and the function-level coverage record comes first.
      source = """
      defmodule W do
        def f(x, y) do
          with {:ok, a} <- x, {:ok, b} when b > 1 <- y do
            a + b
          else
            {:error, e} when e > 2 -> e
          end
        end
      end
      """

      {mentions, sites} = mentions(source, [:relational])
      assert Enum.map(sites, & &1.line) == [3, 3, 6, 6]

      assert mentions ==
               for(
                 kind <- [:record, :branch, :exclusion],
                 id <- 1..4,
                 do: %{kind: kind, id: id, within: nil}
               )
    end

    test "`for` generators and multi-pattern `catch` clauses are sequences too" do
      source = """
      defmodule S do
        def f(xs), do: for(x when x > 1 <- xs, do: x)

        def g(fun) do
          try do
            fun.()
          catch
            :throw, v when v > 1 -> v
          end
        end
      end
      """

      {mentions, sites} = mentions(source, [:relational])
      site_ids = Enum.map(sites, & &1.id)
      assert length(site_ids) == 4
      assert ids(mentions, :branch) == site_ids
      assert ids(mentions, :exclusion) == site_ids
    end

    test "a gated `case` or multi-argument `fn` clause is a branch, its original an exclusion" do
      source = """
      defmodule C do
        def f(x) do
          case x do
            n when n > 1 -> n
            _ -> 0
          end
        end

        def g(xs), do: Enum.reduce(xs, 0, fn x, acc when x > acc -> x; _, acc -> acc end)
      end
      """

      {mentions, sites} = mentions(source, [:relational])
      site_ids = Enum.map(sites, & &1.id)
      assert length(site_ids) == 4
      assert ids(mentions, :branch) == site_ids
      assert ids(mentions, :exclusion) == site_ids
    end

    test "a `receive` clause's mutants are mentioned once, its `after` block walked too" do
      source = """
      defmodule Rc do
        def f(t) do
          receive do
            {:msg, n} -> n + 1
          after
            t -> t - 1
          end
        end
      end
      """

      {mentions, sites} = mentions(source, [:arithmetic])
      assert Enum.map(sites, & &1.line) == [4, 6]
      assert for(%{kind: :branch, id: id} <- mentions, do: id) == Enum.map(sites, & &1.id)
    end

    test "a comparison with a non-literal is no exclusion" do
      source = """
      defmodule X do
        def f(mutare_active, x) when :erlang."=/="(mutare_active, x), do: x

        def g(mutare_active, x)
            when :erlang.orelse(:erlang.<(mutare_active, x), :erlang.>(mutare_active, 9)),
            do: x

        def h(mutare_active, x)
            when :erlang.orelse(:erlang.<(mutare_active, 3), :erlang.>(mutare_active, x)),
            do: x
      end
      """

      assert Manifest.from_source(source, :mutare_active).mentions == []
    end

    test "source that merely resembles a construct mentions nothing" do
      # Variables named like the guard-sequence forms, the forms called without blocks, and a
      # `receive` whose `do` block is empty.
      source = """
      defmodule Odd do
        def f(x, for, with, try) do
          receive do
          after
            0 -> :ok
          end

          receive(x)
          with(x)
          try(x)
          case x, do: x
          {for, with, try}
        end
      end
      """

      assert Manifest.from_source(source, :mutare_active).mentions == []
    end

    test "a mention inside another mutant's branch names that mutant as `within`" do
      source = """
      defmodule N do
        def f(mutare_active, x) do
          case mutare_active do
            1 ->
              case mutare_active do
                2 -> x - 1
                mutare_active -> x
              end

            mutare_active ->
              x + 1
          end
        end
      end
      """

      assert Manifest.from_source(source, :mutare_active).mentions == [
               %{kind: :branch, id: 1, within: nil},
               %{kind: :branch, id: 2, within: 1}
             ]
    end
  end
end
