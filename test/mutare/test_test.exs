defmodule Mutare.TestTest do
  # Not async: the live-mutant helpers drive selection through `:persistent_term`, a VM-global
  # slot every compiled metamutant reads (see `Mutare.Test`'s module warning and `selector_test`).
  use ExUnit.Case, async: false

  import Mutare.Test

  alias Mutare.MutationSite
  alias Mutare.Mutator.Spec
  alias Mutare.Mutators.{Arithmetic, ClauseDrop, CollectionArity, Relational, ReturnValue}

  doctest Mutare.Test

  describe "node_mutations/3" do
    test "renders the mutations a single mutator offers for a node" do
      assert node_mutations("1 + 2", Arithmetic) == ["1 - 2"]
    end

    test "accepts a list of mutators and a Spec, not just a bare module" do
      assert node_mutations("a >= b", [Relational]) == ["a > b", "a <= b"]
      assert node_mutations("1 + 2", Spec.for_module(Arithmetic)) == ["1 - 2"]
    end

    test "no mutator matches → no mutations" do
      assert node_mutations("a >= b", Arithmetic) == []
    end

    test "pipe_mode recovers the effective arity of a pipe stage" do
      # The written call and the equivalent pipe stage produce the same mutant: the
      # piped value is an implicit extra arg, so `Enum.sort()` piped == `Enum.sort(x)`.
      assert node_mutations("Enum.sort(coll)", CollectionArity) == ["Enum.reverse(coll)"]
      assert node_mutations("Enum.sort()", CollectionArity, :piped) == ["Enum.reverse()"]

      # Without the flag the stage reads as arity 0, which matches nothing.
      assert node_mutations("Enum.sort()", CollectionArity) == []
    end
  end

  describe "diffs/2" do
    test "records every site, in order, as {name, original, mutated}" do
      assert diffs("def f(a, b), do: a + b", [Arithmetic]) ==
               [{:arithmetic, "a + b", "a - b"}]
    end

    test "captures the structural siblings the transform also records" do
      diffs = diffs("def f(a, b), do: a + b", [Arithmetic, ReturnValue])

      assert {:arithmetic, "a + b", "a - b"} in diffs
      # ReturnValue rewrites the clause's return tail to its sentinels.
      assert Enum.any?(diffs, &match?({:return_value, "a + b", _}, &1))
    end

    test "a multi-clause function surfaces the clause_drop family" do
      source = "def f(0), do: :zero\ndef f(n), do: n + 1"
      diffs = diffs(source, [Arithmetic, ClauseDrop])

      assert {:clause_drop, "def f(0), do: :zero", ""} in diffs
      assert {:clause_drop, "def f(n), do: n + 1", ""} in diffs
      assert {:arithmetic, "n + 1", "n - 1"} in diffs
    end

    test "clause_drop is a registered family: narrowing the set switches it off" do
      # It is transform-managed (no producing callback), so it is discovered by module identity
      # rather than invoked — the gate is easy to lose. Pin that asking for one family really
      # does exclude it.
      source = "def f(0), do: :zero\ndef f(n), do: n + 1"

      assert diffs(source, [Arithmetic]) == [{:arithmetic, "n + 1", "n - 1"}]
      assert Enum.all?(diffs(source, [ClauseDrop]), &match?({:clause_drop, _, ""}, &1))
    end

    test "resolution runs: an imported call is matched like a qualified one" do
      source = "import Enum\ndef f(xs), do: reject(xs, & &1)"
      diffs = diffs(source, [Mutare.Mutators.Collection])

      # `reject` resolves to `Enum.reject` and is rewritten to its sibling `filter`.
      assert Enum.any?(diffs, fn {name, original, _} ->
               name == :collection and original =~ "reject"
             end)
    end
  end

  describe "diffs_for/3" do
    @mutators [Arithmetic, ReturnValue]
    @source "def f(a, b), do: a + b"

    test "isolates one family from the structural siblings" do
      assert diffs_for(@source, @mutators, :arithmetic) == [{"a + b", "a - b"}]
    end

    test "selects the other family by name" do
      pairs = diffs_for(@source, @mutators, :return_value)

      assert pairs != []
      assert Enum.all?(pairs, fn {original, _} -> original == "a + b" end)
    end

    test "an unknown family name selects nothing" do
      assert diffs_for(@source, @mutators, :nonexistent) == []
    end
  end

  describe "options passthrough (diffs/3, diffs_for/4, metamutant_source/3)" do
    # A source whose diff depends on a transform option: the declarative `:call_routes`
    # skip suppresses the mutation inside the routed call, so the option observably arrived.
    @routed_source """
    defmodule M do
      import Mutare.Test.RoutingExtension
      def f(x), do: opaque(x + 1)
    end
    """
    @skip_route [{Mutare.Test.RoutingExtension, :opaque, 1, :raw}]

    test "diffs/3 forwards transform options" do
      assert {:arithmetic, "x + 1", "x - 1"} in diffs(@routed_source, [Arithmetic])
      assert diffs(@routed_source, [Arithmetic], call_routes: @skip_route) == []
    end

    test "diffs_for/4 forwards transform options" do
      assert diffs_for(@routed_source, [Arithmetic], :arithmetic) == [{"x + 1", "x - 1"}]
      assert diffs_for(@routed_source, [Arithmetic], :arithmetic, call_routes: @skip_route) == []
    end

    test "the mutators argument overrides a :mutators passed in opts" do
      diffs = diffs("def f(a, b), do: a + b", [Arithmetic], mutators: [Relational])

      assert {:arithmetic, "a + b", "a - b"} in diffs
      refute Enum.any?(diffs, &match?({:relational, _, _}, &1))
    end
  end

  describe "metamutant_source/3" do
    test "returns the rendered metamutant for =~ scaffolding assertions" do
      metamutant = metamutant_source("defmodule Q do\n  def n, do: 1 + 1\nend", [Arithmetic])

      # The woven selector carries the mutant branch — visible only in the rendered source.
      assert metamutant =~ "1 - 1"
      assert metamutant =~ "1 + 1"
    end

    test "forwards transform options" do
      refute metamutant_source(@routed_source, [Arithmetic], call_routes: @skip_route) =~
               "x - 1"
    end
  end

  describe "assert_metamutant_compiles/2" do
    test "passes for a complete module and returns the (purged) compiled modules" do
      source = "defmodule Mutare.TestTest.Sample do\n  def f(a, b), do: a + b\nend"

      compiled = assert_metamutant_compiles(source, [Arithmetic])

      assert [{module, binary} | _] = compiled
      assert is_atom(module)
      assert is_binary(binary)
      # Purged on the way out (the wrapper shell too), so nothing leaks.
      refute :code.is_loaded(module)
    end

    test "is callable twice for the same source without a redefinition clash" do
      source = "defmodule Mutare.TestTest.Twice do\n  def g(n), do: n * 2\nend"

      # Each call compiles under its own wrapper, so the same source can't redefine one name.
      assert_metamutant_compiles(source, [Arithmetic])
      assert [_ | _] = assert_metamutant_compiles(source, [Arithmetic])
    end

    test "fails for a source that is not a complete compilation unit" do
      # No `defmodule` ⇒ the metamutant compiles to zero modules.
      assert_raise ExUnit.AssertionError, ~r/no modules/, fn ->
        assert_metamutant_compiles("x = 1 + 2", [Arithmetic])
      end
    end

    test "forwards transform options (the routed fixture still compiles)" do
      assert [_ | _] =
               assert_metamutant_compiles(@routed_source, [Arithmetic],
                 extensions: [Mutare.Test.RoutingExtension]
               )
    end
  end

  describe "compile_metamutant/3" do
    test "compiles the metamutant and returns the modules plus public mutant DTOs" do
      {modules, sites} =
        compile_metamutant("defmodule Q do\n  def n, do: 1 + 1\nend", [Arithmetic])

      assert [module] = modules
      assert Code.ensure_loaded?(module)
      # Baseline (no mutant active) runs the original.
      assert module.n() == 2

      assert Enum.any?(
               sites,
               &match?(%MutationSite{original_code: "1 + 1", mutated_code: "1 - 1"}, &1)
             )
    end

    test "isolates each compile so two calls on the same source don't clash" do
      source = "defmodule Q do\n  def n, do: 2 * 3\nend"

      {[first], _} = compile_metamutant(source, [Arithmetic])
      {[second], _} = compile_metamutant(source, [Arithmetic])

      refute first == second
    end

    test "the isolating wrapper preserves self-references and a real top-level module" do
      # The fixture's `Q` is nested under the wrapper, so `Q.twice/1` must still resolve (Elixir's
      # nested-alias rule) and the fixture must NOT collide with the real top-level `Enum` it also
      # defines — `Sandbox.<n>.Enum` is a separate module from `Elixir.Enum`.
      source = """
      defmodule Q do
        def n, do: Q.twice(1 + 1)
        def twice(x), do: x * 2
      end

      defmodule Enum do
        def shadowed?, do: true
      end
      """

      {modules, _sites} = compile_metamutant(source, [Arithmetic])

      q = Enum.find(modules, &(Module.split(&1) |> List.last() == "Q"))
      assert q.n() == 4
      # The real Enum is untouched: still the stdlib module, not the fixture's.
      assert Enum.sum([1, 2, 3]) == 6
    end

    test "the `mutators` argument overrides a `:mutators` passed in opts" do
      {_modules, sites} =
        compile_metamutant("defmodule Q do\n  def n, do: 1 + 1\nend", [Arithmetic],
          mutators: [Relational]
        )

      assert Enum.all?(sites, &(&1.mutator == :arithmetic))
      refute sites == []
    end

    test "uniquify: false compiles at the real top-level name (no wrapper nesting)" do
      # The escape hatch (see the nesting caveat in the module doc): with no wrapper, the
      # metamutant keeps its own top-level name, so `__MODULE__`/struct identity is the written
      # name and a namespaced fixture could reach a real same-prefix sibling. The caller owns
      # isolation; we use a name that can't collide with a real module and is purged on exit.
      {[mod], _sites} =
        compile_metamutant(
          "defmodule Mutare.TestTest.Unwrapped do\n  def who, do: __MODULE__\nend",
          [Arithmetic],
          uniquify: false
        )

      # Not nested under a `Sandbox.M<n>` wrapper: the module — and `__MODULE__` — is the
      # written name verbatim, the opposite of the default isolating path.
      assert mod == Mutare.TestTest.Unwrapped
      assert mod.who() == Mutare.TestTest.Unwrapped
    end
  end

  describe "with_active_mutant/2" do
    test "drives a chosen mutant live and restores the baseline after" do
      {[mod], sites} =
        compile_metamutant("defmodule Q do\n  def n, do: 1 + 1\nend", [Arithmetic])

      id = site_id(sites, {"1 + 1", "1 - 1"})

      assert mod.n() == 2
      assert with_active_mutant(id, fn -> mod.n() end) == 0
      # Restored, so the next assertion sees the baseline again.
      assert mod.n() == 2
    end

    test "drives a live mutant in lifted (dispatcher) code, wrapped" do
      # A `when` guard is lifted: the clause becomes a private `__mutare_*` function the dispatcher
      # tail-calls, threading the active id. That local call + extra param is the structurally
      # trickiest generated code under the wrapper's nesting, so prove it activates live.
      {[mod], sites} =
        compile_metamutant(
          "defmodule Q do\n  def f(n) when n > 0, do: :pos\n  def f(_), do: :other\nend",
          [Relational]
        )

      # The boundary mutant `n > 0` → `n >= 0` admits 0.
      id = site_id(sites, {"n > 0", "n >= 0"})

      assert mod.f(0) == :other
      assert with_active_mutant(id, fn -> mod.f(0) end) == :pos
      assert mod.f(0) == :other
    end
  end

  describe "observe_mutant/3" do
    test "returns the baseline and mutated observations as a pair, then restores" do
      {[mod], sites} =
        compile_metamutant("defmodule Q do\n  def n, do: 1 + 1\nend", [Arithmetic])

      assert observe_mutant(sites, {"1 + 1", "1 - 1"}, fn -> mod.n() end) == {2, 0}
      # The active selection is restored after both runs.
      assert mod.n() == 2
    end

    test "pins the baseline explicitly, even under a leaked active selection" do
      {[mod], sites} =
        compile_metamutant("defmodule Q do\n  def n, do: 1 + 1\nend", [Arithmetic])

      id = site_id(sites, {"1 + 1", "1 - 1"})

      # A hostile leak: some earlier code left the mutant active. The baseline
      # observation must still be the original program, not the leaked mutant.
      Mutare.Selector.put(id)

      try do
        assert observe_mutant(sites, {"1 + 1", "1 - 1"}, fn -> mod.n() end) == {2, 0}
      after
        Mutare.Selector.put(Mutare.Selector.baseline())
      end
    end

    test "flunks before running fun when the pattern matches no site" do
      {[mod], sites} =
        compile_metamutant("defmodule Q do\n  def n, do: 1 + 1\nend", [Arithmetic])

      assert_raise ExUnit.AssertionError, ~r/no site matching/, fn ->
        observe_mutant(sites, {"nope", "nope"}, fn -> mod.n() end)
      end
    end
  end

  describe "RoutingExtension" do
    alias Mutare.Test.RoutingExtension

    @opaque_source """
    defmodule M do
      import Mutare.Test.RoutingExtension
      def f(x), do: opaque(x + 1)
    end
    """

    @tagged_source """
    defmodule M do
      import Mutare.Test.RoutingExtension
      def f(x), do: tagged(x + 1, x * 2)
    end
    """

    test "a foreign :skip route leaves the whole call opaque" do
      # Unrouted (the extension not enabled), the argument mutates — the contrast that
      # isolates the route as what suppresses it.
      assert {:arithmetic, "x + 1", "x - 1"} in diffs(@opaque_source, [Arithmetic])

      assert diffs(@opaque_source, [Arithmetic], extensions: [RoutingExtension]) == []
    end

    test "per-argument routing mutates the :expression argument, never the :skip one" do
      muts = diffs(@tagged_source, [Arithmetic], extensions: [RoutingExtension])

      assert {:arithmetic, "x + 1", "x - 1"} in muts
      refute Enum.any?(muts, fn {_family, original, _mutated} -> original == "x * 2" end)

      # Without the routes both arguments mutate.
      assert {:arithmetic, "x * 2", "x / 2"} in diffs(@tagged_source, [Arithmetic])
    end

    test "the pass-through macros expand: the routed metamutant compiles and runs live" do
      {[mod], sites} =
        compile_metamutant(@tagged_source, [Arithmetic], extensions: [RoutingExtension])

      # `tagged(x + 1, x * 2)` expands to `x + 1`; the surviving expression mutant flips it.
      assert observe_mutant(sites, {"x + 1", "x - 1"}, fn -> mod.f(1) end) == {2, 0}
    end
  end

  describe "site_id/2 and site_by/3" do
    @sites [
      %{id: 1, mutator: :arithmetic, original_code: "a + b", mutated_code: "a - b"},
      %{id: 2, mutator: :relational, original_code: "a > b", mutated_code: "a >= b"}
    ]

    test "site_id resolves the id from a logical diff" do
      assert site_id(@sites, {"a + b", "a - b"}) == 1
    end

    test "site_id matches exactly, not as a substring" do
      sites = [
        %{id: 7, mutator: :arithmetic, original_code: "11 + 1", mutated_code: "11 - 1"}
      ]

      # `"1 + 1"` is a substring of `"11 + 1"`; exact matching must NOT resolve it.
      assert_raise ExUnit.AssertionError, ~r/no site matching/, fn ->
        site_id(sites, {"1 + 1", "1 - 1"})
      end

      assert site_id(sites, {"11 + 1", "11 - 1"}) == 7
    end

    test "site_id resolves a Regex slot by pattern, for whole-statement diffs" do
      sites = [
        %{
          id: 4,
          mutator: :custom,
          original_code: "from(u in User, limit: 2)",
          mutated_code: "from(u in User, limit: 3)"
        }
      ]

      # A fragment can't name the whole enclosing expression verbatim; a regex slot can.
      assert site_id(sites, {~r/limit: 2/, ~r/limit: 3/}) == 4
      # Slots opt in independently: pin one exactly, loosen the other.
      assert site_id(sites, {"from(u in User, limit: 2)", ~r/limit: 3/}) == 4
    end

    test "an anchored Regex recovers exactness within the loose mode" do
      sites = [
        %{id: 7, mutator: :arithmetic, original_code: "11 + 1", mutated_code: "11 - 1"}
      ]

      # A loose `1 + 1` regex would resolve against the `11 + 1` site — anchor it to refuse.
      assert_raise ExUnit.AssertionError, ~r/no site matching/, fn ->
        site_id(sites, {~r/\b1 \+ 1\b/, ~r/\b1 - 1\b/})
      end

      assert site_id(sites, {~r/11 \+ 1/, ~r/11 - 1/}) == 7
    end

    test "site_id flunks when a Regex pair matches more than one site" do
      sites = [
        %{id: 1, mutator: :arithmetic, original_code: "a + b", mutated_code: "a - b"},
        %{id: 2, mutator: :arithmetic, original_code: "a + c", mutated_code: "a - c"}
      ]

      assert_raise ExUnit.AssertionError, ~r/ambiguous: 2 sites/, fn ->
        site_id(sites, {~r/a \+/, ~r/a -/})
      end
    end

    test "site_by returns the whole matching site" do
      assert %{id: 2} = site_by(@sites, "the relational one", &(&1.mutator == :relational))
    end

    test "flunks when nothing matches" do
      assert_raise ExUnit.AssertionError, ~r/no site matching/, fn ->
        site_id(@sites, {"x", "y"})
      end
    end

    test "flunks when more than one matches" do
      assert_raise ExUnit.AssertionError, ~r/ambiguous: 2 sites/, fn ->
        site_by(@sites, "anything", fn _ -> true end)
      end
    end
  end
end
