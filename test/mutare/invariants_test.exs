defmodule Mutare.InvariantsTest do
  @moduledoc """
  `verify_invariants: true` — the transform reads its rendered metamutant back, renders the
  source a second time, and raises `Mutare.InvariantError` when the result is unsound.

  The integration cases drive real transforms: core's own output passes under selection, poison
  skips, ignores, and runtime namespaces, while the fixtures in `invariant_fixtures.ex` each break
  one invariant the way a custom mutator or host can. The unit cases hand
  `Mutare.Transform.Invariants.check!/3` a written-out metamutant, for the violations no fixture
  produces on purpose.
  """
  use ExUnit.Case, async: true

  alias Mutare.{InvariantError, Site}
  alias Mutare.Transform.{Config, Invariants}

  # Every delivery path core has: lifted guards and head patterns with clause drops, tupled
  # `case` clauses, per-clause `fn` and `receive`, guard-sequence `with`, rescue selection, pipe
  # hoisting, default arguments, and a host-woven fragment. Only `guarded/2`'s first clause has
  # mutants of its own, so its drop — claimed after them — extends their run, and the exclusion
  # it relies on is written in the range form.
  @wide """
  defmodule Wide do
    import Mutare.Test.HostDSL

    def guarded(a, b) when a > 1 and b < 2, do: a + b
    def guarded(_, _), do: nil

    def zero(0), do: :zero
    def zero(_), do: nil

    def branches(x) do
      case x do
        {:ok, n} when n > 0 -> n * 2
        _ -> 0
      end
    end

    def closure(xs), do: Enum.map(xs, fn n when n > 1 -> n - 1; n -> n end)

    def waits(timeout) do
      receive do
        {:msg, n} when n > 1 -> n + 1
      after
        timeout -> :none
      end
    end

    def chained(x) do
      with {:ok, y} when y > 1 <- x do
        y + 1
      else
        {:error, e} when e > 2 -> e
      end
    end

    def rescued(f) do
      try do
        f.()
      rescue
        ArgumentError -> :arg
        RuntimeError -> :rt
      end
    end

    def piped(xs), do: xs |> Enum.sort() |> Enum.take(2)

    def defaults(a, b \\\\ 1), do: a - b

    def hosted(x), do: filter([:ok], x > 1)

    def ignored(x), do: x * 3 # mutare:ignore
  end
  """

  @wide_mutators [:builtins, Mutare.Test.HostMutator]

  defp verified(source, opts),
    do: Mutare.Transform.transform_string_with_sites(source, [verify_invariants: true] ++ opts)

  defp violations(source, opts) do
    error = assert_raise InvariantError, fn -> verified(source, opts) end
    error.violations
  end

  describe "core's own output" do
    test "passes for every delivery path, standalone and under a runtime namespace" do
      %{sites: sites, metamutant: metamutant} = verified(@wide, mutators: @wide_mutators)

      # Not vacuous: the source reaches the shapes the checks read differently.
      assert Enum.any?(sites, &(&1.mutator == :clause_drop))
      assert Enum.any?(sites, &(&1.mutator == :host_filter))
      assert Enum.any?(sites, & &1.ignored)
      assert metamutant =~ ~r/:erlang\.orelse\(\s*:erlang\.<\(mutare_active/

      verified(@wide, mutators: @wide_mutators, start_id: 40, runtime_namespace: "lib/wide.ex")
    end

    test "passes when selection, poison skips, and ignores withhold mutants" do
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@wide, mutators: @wide_mutators)

      ids = Enum.map(sites, & &1.id)
      {selected, _rest} = Enum.split(ids, div(length(ids), 2))

      verified(@wide, mutators: @wide_mutators, emit_ids: MapSet.new(selected))
      verified(@wide, mutators: @wide_mutators, skip_ids: MapSet.new(Enum.take_every(ids, 3)))

      verified(@wide,
        mutators: @wide_mutators,
        start_id: 7,
        runtime_namespace: "lib/wide.ex",
        emit_ids: MapSet.new(selected, &(&1 + 6)),
        skip_ids: MapSet.new([7, 9])
      )
    end

    test "passes when nothing is delivered and the metamutant is the source itself" do
      assert %{metamutant: @wide} =
               verified(@wide, mutators: @wide_mutators, emit_ids: MapSet.new())
    end
  end

  describe "a host that overwrites core's selectors" do
    @clobbered """
    defmodule Clobbered do
      import Mutare.Test.HostDSL

      def f(q, x), do: filter(q, x > 1)
    end
    """

    @clobbering [:integer, Mutare.Test.ClobberingHostMutator]

    test "goes unnoticed without the checks" do
      %{metamutant: metamutant, sites: sites} =
        Mutare.Transform.transform_string_with_sites(@clobbered, mutators: @clobbering)

      assert [_, _] = for(%{mutator: :integer} = site <- sites, do: site)
      refute metamutant =~ "x > 0"
    end

    test "leaves core's mutants with neither a branch nor a coverage record" do
      violations = violations(@clobbered, mutators: @clobbering)

      integer = for {kind, %Site{mutator: :integer} = site} <- violations, do: {kind, site.id}

      assert Enum.sort(integer) == [
               missing_branch: 1,
               missing_branch: 2,
               missing_record: 1,
               missing_record: 2
             ]

      assert length(violations) == 4
    end
  end

  test "a replacement that keeps the original literal's metadata renders unchanged" do
    source = "defmodule A do\n  def f(x), do: x + 1\nend\n"

    assert [
             {:unchanged_mutant,
              %Site{mutator: :stale_token, original_code: "1", mutated_code: "1"}}
           ] =
             violations(source, mutators: [Mutare.Test.StaleTokenMutator])
  end

  test "a nondeterministic mutator makes the second pass differ" do
    source = "defmodule A do\n  def f(x), do: x + 1\nend\n"

    assert [{:nondeterministic_render, differences}] =
             violations(source, mutators: [Mutare.Test.UniqueLiteralMutator])

    assert differences == [
             "the emitted program differs",
             "mutant #1 (unique_literal at nofile:2) changed its `mutated_code`"
           ]
  end

  test "Mutare.Test's source helpers check by default, and take an opt-out" do
    source = "defmodule A do\n  def f(x), do: x + 1\nend\n"

    assert_raise InvariantError, fn ->
      Mutare.Test.diffs(source, [Mutare.Test.StaleTokenMutator])
    end

    assert Mutare.Test.diffs(source, [Mutare.Test.StaleTokenMutator], verify_invariants: false) ==
             [{:stale_token, "1", "1"}]
  end

  describe "check!/3 on a written-out metamutant" do
    # Hoisted selectors (`case mutare_active do`) and a literal `:mutare_cov` record keep these
    # sources independent of the selector key, which a self-hosted run changes.
    defp site(id, fields \\ []) do
      struct!(
        %Site{
          id: id,
          file: "lib/m.ex",
          line: id,
          mutator: :fixture,
          original_code: "x",
          mutated_code: "y#{id}"
        },
        fields
      )
    end

    defp record(ids),
      do: "case true do\n true -> :mutare_cov.hit([#{Enum.join(ids, ", ")}])\n _ -> false\n end"

    # What one emit pass produced: the emitted tree's fingerprint, and the mutants it recorded.
    defp emitted(sites, fields \\ []),
      do:
        Enum.into(fields, %{
          program: 1,
          sites: sites,
          next_id: length(sites) + 1,
          dispatch_var: :mutare_active
        })

    defp check(metamutant, sites, reemitted \\ nil) do
      rendered = %{
        metamutant: metamutant,
        sites: sites,
        next_id: length(sites) + 1,
        dispatch_var: :mutare_active
      }

      first = emitted(sites)
      Invariants.check!(rendered, first, %Config{file: "lib/m.ex"}, fn -> reemitted || first end)
    end

    defp check_violations(metamutant, sites, reemitted \\ nil) do
      error = assert_raise InvariantError, fn -> check(metamutant, sites, reemitted) end
      assert error.file == "lib/m.ex"
      {error.violations, error.message}
    end

    defp module(body) do
      """
      defmodule M do
        def f(mutare_active, x) do
          #{body}
        end
      end
      """
    end

    test "accepts a selector whose mutants are each branched and recorded" do
      source =
        module("""
        case mutare_active do
          1 -> x - 1
          2 -> x * 1
          mutare_active ->
            #{record([1, 2])}
            x + 1
        end
        """)

      assert check(source, [site(1), site(2)]) == :ok
    end

    test "a branch only inside another mutant's branch is unreachable" do
      source =
        module("""
        case mutare_active do
          1 ->
            case mutare_active do
              2 -> x - 1
              mutare_active -> x
            end
          mutare_active ->
            #{record([1, 2])}
            x + 1
        end
        """)

      {violations, message} = check_violations(source, [site(1), site(2)])
      assert [{:unreachable_branch, %Site{id: 2}, [{1, %Site{id: 1}}]}] = violations

      assert message =~
               "mutant #2 (fixture, lib/m.ex:2) `x` → `y2` has branches only inside the branch of mutant #1"
    end

    test "an exclusion selects a dropped clause, but no other mutant" do
      source = """
      defmodule M do
        def f(mutare_active, x) when :erlang."=/="(mutare_active, 1) and :erlang."=/="(mutare_active, 2) do
          #{record([1, 2])}
          x
        end
      end
      """

      assert {[{:missing_branch, %Site{id: 2}}], _message} =
               check_violations(source, [site(1, operation: :delete), site(2)])
    end

    test "branches and records for ids the transform did not deliver are strays" do
      source =
        module("""
        case mutare_active do
          1 -> x - 1
          2 -> x * 1
          5 -> x / 1
          mutare_active ->
            #{record([1, 3, 6])}
            x + 1
        end
        """)

      sites = [site(1), site(2, ignored: true), site(3, poisoned: true)]
      {violations, message} = check_violations(source, sites)

      assert [
               {:stray_branch, {2, %Site{id: 2}}},
               {:stray_branch, {5, nil}},
               {:stray_record, {3, %Site{id: 3}}},
               {:stray_record, {6, nil}}
             ] = violations

      assert message =~
               "the metamutant has a branch for mutant #2 (fixture, lib/m.ex:2) `x` → `y2` (ignored)"

      assert message =~ "the metamutant has a branch for id 5, which no mutant records"

      assert message =~
               "a coverage record lists mutant #3 (fixture, lib/m.ex:3) `x` → `y3` (poisoned)"
    end

    test "a coverage record inside a mutant branch never fires, so it records nothing" do
      source =
        module("""
        case mutare_active do
          1 ->
            #{record([1])}
            x - 1
          mutare_active -> x + 1
        end
        """)

      assert {[{:missing_record, %Site{id: 1}}], message} = check_violations(source, [site(1)])
      assert message =~ "no coverage record lists mutant #1"
    end

    test "reports every kind in order, each described in full" do
      source =
        module("""
        case mutare_active do
          3 ->
            case mutare_active do
              2 -> x - 1
              mutare_active -> x
            end
          5 -> x / 1
          mutare_active ->
            #{record([2, 3, 6])}
            x + 1
        end
        """)

      sites = [
        site(1, mutated_code: "x"),
        site(2, original_code: "a +\n  b", mutated_code: "a -\n  b"),
        site(3)
      ]

      {violations, message} = check_violations(source, sites, emitted(sites, next_id: 5))

      assert Enum.map(violations, &elem(&1, 0)) == [
               :missing_branch,
               :unreachable_branch,
               :stray_branch,
               :missing_record,
               :stray_record,
               :unchanged_mutant,
               :nondeterministic_render
             ]

      assert message == """
             invariant check failed for lib/m.ex (7 violations):

               * mutant #1 (fixture, lib/m.ex:1) `x` → `x` has no branch in the metamutant: \
             activating it runs the original code, so no test can kill it
               * mutant #2 (fixture, lib/m.ex:2) `a + b` → `a - b` has branches only inside the \
             branch of mutant #3 (fixture, lib/m.ex:3) `x` → `y3`: no run that activates it alone \
             reaches them, so no test can kill it
               * the metamutant has a branch for id 5, which no mutant records
               * no coverage record lists mutant #1 (fixture, lib/m.ex:1) `x` → `x`, so the run \
             would record it as uncovered and never test it
               * a coverage record lists id 6, which no mutant records
               * mutant #1 (fixture, lib/m.ex:1) `x` → `x` renders identically to the original, so \
             no test can kill it (a replacement that keeps the original node's metadata re-renders \
             the original text; build literals with `Mutare.AST.literal/1`)
               * emitting the file a second time gave a different result (next id 4, then 5); \
             report-time diffs are re-rendered, so they could describe other mutants than the ones \
             that ran

             Each is a bug in Mutare or in a custom mutator, host, or extension enabled for this \
             run, not in the project under test.\
             """
    end

    test "names a mutant without rendered code by family and location alone" do
      error =
        InvariantError.exception(
          file: "lib/m.ex",
          violations: [{:missing_branch, site(1, original_code: nil, mutated_code: nil)}]
        )

      assert error.message =~
               "invariant check failed for lib/m.ex (1 violation):\n\n" <>
                 "  * mutant #1 (fixture, lib/m.ex:1) has no branch"
    end

    test "one reachable branch suffices; copies inside other branches are dead code" do
      source =
        module("""
        case mutare_active do
          1 ->
            case mutare_active do
              2 -> x - 1
              mutare_active -> x
            end
          2 -> x * 1
          mutare_active ->
            #{record([1, 2])}
            x + 1
        end
        """)

      assert check(source, [site(1), site(2)]) == :ok
    end

    test "lists each enclosing mutant and each stray id once, in id order" do
      # Written out of id order, with mutant 2 twice inside mutant 3's branch.
      source =
        module("""
        case mutare_active do
          3 ->
            case mutare_active do
              2 -> x - 1
              mutare_active ->
                case mutare_active do
                  2 -> x - 4
                  mutare_active -> x
                end
            end
          4 ->
            case mutare_active do
              2 -> x - 2
              mutare_active -> x
            end
          1 ->
            case mutare_active do
              2 -> x - 3
              mutare_active -> x
            end
          mutare_active ->
            #{record([1, 2, 3, 4, 7, 6, 7])}
            x + 1
        end
        """)

      sites = [site(1), site(2), site(3), site(4)]

      assert {[{:unreachable_branch, %Site{id: 2}, enclosing}, stray_six, stray_seven], message} =
               check_violations(source, sites)

      assert Enum.map(enclosing, &elem(&1, 0)) == [1, 3, 4]
      assert {stray_six, stray_seven} == {{:stray_record, {6, nil}}, {:stray_record, {7, nil}}}

      assert message =~
               "only inside the branch of mutant #1 (fixture, lib/m.ex:1) `x` → `y1`, " <>
                 "mutant #3 (fixture, lib/m.ex:3) `x` → `y3`, mutant #4 (fixture, lib/m.ex:4) " <>
                 "`x` → `y4`: no run"
    end

    for {name, source} <- [
          mismatched_delimiter: "defmodule M do\n  def f(x), do: (x\nend\n",
          missing_terminator: "defmodule M do\n  def f(x), do: x\n",
          syntax: "defmodule M do\n  def f(x), do: x +* 1\nend\n"
        ] do
      test "an unparseable metamutant (#{name}) is reported instead of read back" do
        assert {[{:unparseable_metamutant, reason}], message} =
                 check_violations(unquote(source), [site(1)])

        assert message =~ "  * the rendered metamutant does not parse: #{reason}\n"
      end
    end

    test "a second pass names only the parts that differ" do
      source =
        module(
          "case mutare_active do\n 1 -> x - 1\n 2 -> x * 1\n mutare_active ->\n #{record([1, 2])}\n x\n end"
        )

      sites = [site(1), site(2)]
      three_fields = emitted([site(1), site(2, line: 9, column: 4, note: "n")])

      assert {[
                {:nondeterministic_render,
                 ["mutant #2 (fixture at lib/m.ex:2) changed its `column`, `line`, `note`"]}
              ], _} =
               check_violations(source, sites, three_fields)

      assert {[{:nondeterministic_render, ["2 mutants, then 1"]}], _} =
               check_violations(source, sites, emitted([site(1)], next_id: 3))

      # The mutants are identical and the emitted tree is not: only the program differs.
      assert {[{:nondeterministic_render, ["the emitted program differs"]}], _} =
               check_violations(source, sites, emitted(sites, program: 2))
    end

    test "a second pass that differs everywhere names each difference" do
      source =
        module("case mutare_active do\n 1 -> x - 1\n mutare_active ->\n #{record([1])}\n x\n end")

      sites = [site(1)]

      moved = %{program: 2, sites: [site(1, line: 9)], next_id: 3, dispatch_var: :other}

      assert {[{:nondeterministic_render, differences}], message} =
               check_violations(source, sites, moved)

      assert differences == [
               "the emitted program differs",
               "next id 2, then 3",
               "dispatch variable :mutare_active, then :other",
               "mutant #1 (fixture at lib/m.ex:1) changed its `line`"
             ]

      assert message =~ "different result (#{Enum.join(differences, "; ")}); report-time"
    end
  end
end
