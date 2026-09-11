defmodule Mutare.TransformRedundancyTest do
  # Redundant-mutant suppression: cross-mutator overlap (`Transform.Overlap`), membership
  # (`in`/`not in`) redundancy, and equivalent-sibling collapsing. Split from transform_test.exs.
  use ExUnit.Case, async: true
  import Mutare.Test.Metamutant

  # The families that together exercise membership: Relational flips `in` → `not in`,
  # Logical strips a `not`, Conditional forces a boolean to true/false.
  @membership [Mutare.Mutators.Relational, Mutare.Mutators.Conditional, Mutare.Mutators.Logical]

  # A range guard adds IntegerLiteral for the two integer endpoints; Relational and Conditional
  # exercise the enclosing membership expression.
  @range_guard [
    Mutare.Mutators.IntegerLiteral,
    Mutare.Mutators.Relational,
    Mutare.Mutators.Conditional
  ]

  # For `x in [list]`: List collapses the list to `[]`; Relational/Conditional are the
  # membership pair. The collapse survives in bodies and is suppressed only in guards.
  @membership_list [Mutare.Mutators.Relational, Mutare.Mutators.Conditional, Mutare.Mutators.List]

  # For the double-negation redundancy: Logical strips a `not`/`!`, Conditional forces
  # the boolean true/false.
  @negation [Mutare.Mutators.Conditional, Mutare.Mutators.Logical]

  # For the short-circuit-connective redundancy: Conditional forces a boolean to true/false,
  # Logical swaps `and`↔`or` / `&&`↔`||`.
  @connective [Mutare.Mutators.Conditional, Mutare.Mutators.Logical]

  # For the equality-under-negation survivor: StrictEquality relaxes `===`→`==` (kept under
  # `not`, since it is not the polarity complement), while Relational's flip and Conditional's
  # constants stay suppressed (the membership trio plus the relaxation).
  @strict_negation [
    Mutare.Mutators.StrictEquality,
    Mutare.Mutators.Relational,
    Mutare.Mutators.Conditional,
    Mutare.Mutators.Logical
  ]

  describe "cross-mutator overlap is mutator-agnostic (`Transform.Overlap`)" do
    test "a custom call-rewriting mutator covers its swapped leaf for free, sparing siblings" do
      # `Mutare.Test.CallRewriteMutator` is a third-party mutator — not ModeSwap — that
      # rewrites `Widget.scale(x, :small)` by substituting just `:small` → `:big`, reusing
      # every other operand. Overlap derives the covering footprint from that single-node
      # change via `meta[:mutare_nid]`, with no callback or registration, so the redundant
      # `AtomLiteral` on `:small` is pruned while `:keep` (a value-leaf the rewrite never
      # touches) keeps its AtomLiteral. This pins the "any future minimal-rewrite call mutator
      # gets it for free" promise and the precision of the nid match (only the covered leaf).
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(x), do: {Widget.scale(x, :small), :keep}
          end
          """,
          mutators: [Mutare.Test.CallRewriteMutator, Mutare.Mutators.AtomLiteral]
        )

      pairs = for s <- sites, do: {s.mutator, s.original_code, s.mutated_code}
      atoms = for s <- sites, s.mutator == :atom, do: s.original_code

      # The custom call rewrite is recorded…
      assert {:call_rewrite, "Widget.scale(x, :small)", "Widget.scale(x, :big)"} in pairs
      # …and Overlap pruned the redundant AtomLiteral on the covered `:small` leaf…
      refute ":small" in atoms
      # …but the untouched `:keep` value-leaf keeps its AtomLiteral (precise, not blanket).
      assert ":keep" in atoms
    end
  end

  describe "membership (`in` / `not in`) mutation and redundancy suppression" do
    test "Relational flips `in` to `not in`" do
      assert Mutare.Mutators.Relational.mutate(Sourceror.parse_string!("x in y"))
             |> Enum.map(&Sourceror.to_string/1) == ["x not in y"]
    end

    test "a body `x in y` gets `not in` plus the true/false pair, and compiles" do
      {meta, triples} = membership_triples("def f(x, y), do: x in y")

      assert triples == [
               {:relational, "x in y", "x not in y"},
               {:conditional, "x in y", "true"},
               {:conditional, "x in y", "false"}
             ]

      assert_compiles(meta)
    end

    test "a body `x not in y` strips to `in` (Logical) plus true/false — the inner `in` is not re-offered" do
      {meta, triples} = membership_triples("def f(x, y), do: x not in y")

      # Logical strips the outer `not` (the strongest membership mutation) and
      # Conditional forces the whole thing true/false. The inner `in` is suppressed,
      # so there is NO `not(x not in y)` (Relational re-negation, ≡ the strip) and NO
      # `not true`/`not false` (Conditional on the inner `in`, ≡ the outer true/false):
      # exactly these three mutants, nothing redundant.
      assert {:logical, "x not in y", "x in y"} in triples
      assert {:conditional, "x not in y", "true"} in triples
      assert {:conditional, "x not in y", "false"} in triples
      refute Enum.any?(triples, fn {m, _o, _mut} -> m == :relational end)
      assert length(triples) == 3
      assert_compiles(meta)
    end

    test "a guard `x in [..]` flips to `not in` (lifted) plus true/false, and compiles" do
      {meta, triples} =
        membership_triples("""
        def f(x) when x in [1, 2, 3], do: :ok
        def f(_x), do: :no
        """)

      assert {:relational, "x in [1, 2, 3]", "x not in [1, 2, 3]"} in triples
      assert {:conditional, "x in [1, 2, 3]", "true"} in triples
      assert {:conditional, "x in [1, 2, 3]", "false"} in triples
      assert_compiles(meta)
    end

    test "a guard `x in 1..10` mutates both range endpoints and the membership expression" do
      source = """
      def f(x) when x in 1..10, do: :ok
      def f(_x), do: :no
      """

      module_source = "defmodule M do\n  #{String.trim_trailing(source)}\nend\n"

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(module_source, mutators: @range_guard)

      range_guard_mutants =
        for s <- sites, s.mutator in [:integer, :relational, :conditional] do
          {s.mutator, s.kind, s.original_code, s.mutated_code}
        end

      assert range_guard_mutants == [
               {:integer, :lifted, "1", "2"},
               {:integer, :lifted, "1", "0"},
               {:integer, :lifted, "10", "11"},
               {:integer, :lifted, "10", "9"},
               {:integer, :lifted, "10", "0"},
               {:relational, :lifted, "x in 1..10", "x not in 1..10"},
               {:conditional, :lifted, "x in 1..10", "true"},
               {:conditional, :lifted, "x in 1..10", "false"}
             ]

      assert_compiles(meta)
    end

    test "a guard `x not in [..]` strips to `in` plus true/false — inner `in` suppressed in guards too" do
      {meta, triples} =
        redundancy_triples(
          """
          def f(x) when x not in [1, 2, 3], do: :ok
          def f(_x), do: :no
          """,
          @membership_list ++ [Mutare.Mutators.Logical]
        )

      # Only the membership families on the guard node (clause_drop sites are
      # unrelated). The inner `in` is suppressed in guards too, so exactly the strip
      # and the true/false pair survive — no Relational re-negation, no extra pair.
      membership =
        Enum.filter(triples, fn {m, _o, _mut} -> m in [:relational, :conditional, :logical] end)

      assert {:logical, "x not in [1, 2, 3]", "x in [1, 2, 3]"} in membership
      assert {:conditional, "x not in [1, 2, 3]", "true"} in membership
      assert {:conditional, "x not in [1, 2, 3]", "false"} in membership
      refute Enum.any?(membership, fn {m, _o, _mut} -> m == :relational end)
      assert length(membership) == 3
      refute Enum.any?(triples, fn {m, _o, _mut} -> m == :list end)
      assert_compiles(meta)
    end
  end

  describe "equivalent-sibling suppression (collapsing mutants that compute the same thing)" do
    test "a body `in` keeps the empty-RHS mutant because left-operand evaluation is observable" do
      {meta, triples} =
        redundancy_triples(
          ~S|def f, do: raise("observed") in [1, 2, 3]|,
          @membership_list
        )

      # Emptying only the RHS still evaluates `raise/1`; forcing the whole membership
      # expression to `false` does not. They are therefore distinct body mutants.
      assert {:list, "[1, 2, 3]", "[]"} in triples
      assert {:conditional, ~S|raise("observed") in [1, 2, 3]|, "false"} in triples
      assert_compiles(meta)
    end

    test "a body `not in` also keeps the empty-RHS mutant" do
      {meta, triples} =
        redundancy_triples(
          ~S|def f, do: raise("observed") not in [1, 2, 3]|,
          @membership_list ++ [Mutare.Mutators.Logical]
        )

      assert {:list, "[1, 2, 3]", "[]"} in triples
      assert_compiles(meta)
    end

    test "a standalone list literal still collapses to `[]`" do
      {_meta, triples} = redundancy_triples("def f, do: foo([1, 2, 3])", [Mutare.Mutators.List])
      assert triples == [{:list, "[1, 2, 3]", "[]"}]
    end

    test "a guard `x in [list]`: List is suppressed there too, the membership trio remains" do
      {meta, triples} =
        redundancy_triples(
          """
          def f(x) when x in [1, 2, 3], do: :ok
          def f(_x), do: :no
          """,
          @membership_list
        )

      membership = Enum.filter(triples, fn {m, _o, _mut} -> m in [:relational, :conditional] end)

      assert {:relational, "x in [1, 2, 3]", "x not in [1, 2, 3]"} in membership
      assert {:conditional, "x in [1, 2, 3]", "true"} in membership
      assert {:conditional, "x in [1, 2, 3]", "false"} in membership
      refute Enum.any?(triples, fn {m, _o, _mut} -> m == :list end)
      assert_compiles(meta)
    end

    test "a body `x in %{map}` keeps MapLiteral's `%{}` collapse" do
      {meta, triples} =
        redundancy_triples(
          "def f(x), do: x in %{a: 1}",
          [Mutare.Mutators.MapLiteral, Mutare.Mutators.Conditional]
        )

      assert {:map, "%{a: 1}", "%{}"} in triples
      assert {:conditional, "x in %{a: 1}", "false"} in triples
      assert_compiles(meta)
    end

    test "a body `x in ~w(..)` / `~c\"..\"` keeps both empty and sentinel mutants" do
      for {family, src, sentinel} <- [
            {Mutare.Mutators.WordListLiteral, "~w(a b)", "~w(mutare)"},
            {Mutare.Mutators.CharlistLiteral, ~S|~c"ab"|, ~S|~c"mutare"|}
          ] do
        {meta, triples} =
          redundancy_triples("def f(x), do: x in #{src}", [family, Mutare.Mutators.Conditional])

        assert Enum.any?(triples, fn {_m, _o, mut} -> mut in ["~w()", ~S|~c""|] end)
        assert Enum.any?(triples, fn {_m, _o, mut} -> mut == sentinel end)
        assert {:conditional, "x in #{src}", "true"} in triples
        assert_compiles(meta)
      end
    end

    test "both top-level and nested body `in`-RHS collections keep their `[]` mutants" do
      {meta, triples} =
        redundancy_triples(
          "def f(x, a), do: x in [a, [1, 2]]",
          [Mutare.Mutators.List, Mutare.Mutators.Conditional]
        )

      assert {:list, "[1, 2]", "[]"} in triples
      assert {:list, "[a, [1, 2]]", "[]"} in triples
      assert_compiles(meta)
    end

    test "a guard `x in ~w(..)`: the empty sigil is dropped there too, the sentinel kept" do
      {meta, triples} =
        redundancy_triples(
          """
          def f(x) when x in ~w(a b), do: :ok
          def f(_x), do: :no
          """,
          [Mutare.Mutators.WordListLiteral, Mutare.Mutators.Conditional]
        )

      refute Enum.any?(triples, fn {_m, _o, mut} -> mut == "~w()" end)
      assert {:word_list, "~w(a b)", "~w(mutare)"} in triples
      assert {:conditional, "x in ~w(a b)", "true"} in triples
      assert_compiles(meta)
    end

    test "a body `!(a == b)` / `not (a == b)`: Relational's flip is suppressed (≡ the strip)" do
      for src <- ["!(a == b)", "not (a == b)"] do
        {meta, triples} = redundancy_triples("def f(a, b), do: #{src}", @membership)

        # Logical strips the outer negation → `a == b`, and Conditional forces it
        # true/false. The inner `==` is not offered, so there is NO Relational `!=`
        # (its `!(a != b)` ≡ the strip) and NO inner-Conditional pair (`!true`/`!false`
        # ≡ the outer's): exactly these three, nothing redundant.
        assert triples == [
                 {:conditional, src, "true"},
                 {:conditional, src, "false"},
                 {:logical, src, "a == b"}
               ]

        assert_compiles(meta)
      end
    end

    test "an equality under negation suppresses across `===`/`!=`/`!==` too" do
      for {op, comp} <- [{"==", "!="}, {"!=", "=="}, {"===", "!=="}, {"!==", "==="}] do
        {_meta, triples} = redundancy_triples("def f(a, b), do: not (a #{op} b)", @membership)

        # The exact polarity complement is never offered as a Relational mutant.
        refute {:relational, "not (a #{op} b)", "not (a #{comp} b)"} in triples
        refute Enum.any?(triples, fn {m, _o, _mut} -> m == :relational end)
        assert {:logical, "not (a #{op} b)", "a #{op} b"} in triples
      end
    end

    test "an ordering operator under negation is NOT suppressed (its swaps survive negation)" do
      {meta, triples} = redundancy_triples("def f(a, b), do: !(a > b)", @membership)

      # `!(a >= b)` ≡ `a < b` and `!(a < b)` ≡ `a >= b` — genuinely new mutants, not the
      # strip `a > b`. So Relational stays offered on an ordering operator under `not`/`!`.
      assert {:relational, "a > b", "a >= b"} in triples
      assert {:relational, "a > b", "a < b"} in triples
      assert {:logical, "!(a > b)", "a > b"} in triples
      assert_compiles(meta)
    end

    test "a guard `not (a == b)`: Relational's flip suppressed there too" do
      {meta, triples} =
        redundancy_triples(
          """
          def f(a, b) when not (a == b), do: :ok
          def f(_a, _b), do: :no
          """,
          @membership
        )

      membership =
        Enum.filter(triples, fn {m, _o, _mut} -> m in [:relational, :conditional, :logical] end)

      assert {:logical, "not (a == b)", "a == b"} in membership
      assert {:conditional, "not (a == b)", "true"} in membership
      assert {:conditional, "not (a == b)", "false"} in membership
      refute Enum.any?(membership, fn {m, _o, _mut} -> m == :relational end)
      assert length(membership) == 3
      assert_compiles(meta)
    end

    test "a body `not (a === b)`: StrictEquality's relaxation survives, the complement does not" do
      for {src, inner, relaxed} <- [
            {"not (a === b)", "a === b", "a == b"},
            {"!(a === b)", "a === b", "a == b"},
            {"not (a !== b)", "a !== b", "a != b"},
            {"!(a !== b)", "a !== b", "a != b"}
          ] do
        {meta, triples} = redundancy_triples("def f(a, b), do: #{src}", @strict_negation)

        # `===` → `==` is a *strictness* relaxation, not a polarity flip, so `not (a == b)`
        # ≢ `a === b` (Logical's strip): a genuinely new mutant, KEPT under the negation. The
        # inner equality is now offered (it wasn't before StrictEquality) but only its
        # negation-redundant mutations are dropped — Relational's complement flip (≡ the strip)
        # and Conditional on the inner (≡ the outer's). So exactly the relaxation plus the trio.
        assert triples == [
                 {:strict_equality, inner, relaxed},
                 {:conditional, src, "true"},
                 {:conditional, src, "false"},
                 {:logical, src, inner}
               ]

        assert_compiles(meta)
      end
    end

    test "a guard `not (a === b)`: StrictEquality's relaxation survives there too" do
      {meta, triples} =
        redundancy_triples(
          """
          def f(a, b) when not (a === b), do: :ok
          def f(_a, _b), do: :no
          """,
          @strict_negation
        )

      negation =
        Enum.filter(triples, fn {m, _o, _mut} ->
          m in [:strict_equality, :relational, :conditional, :logical]
        end)

      # The guard twin of the body rule (lifted, since ===/== are guard-legal): the relaxation
      # is kept, the complement flip dropped — the strip/true/false trio plus the relaxation.
      assert {:strict_equality, "a === b", "a == b"} in negation
      assert {:logical, "not (a === b)", "a === b"} in negation
      assert {:conditional, "not (a === b)", "true"} in negation
      assert {:conditional, "not (a === b)", "false"} in negation
      refute Enum.any?(negation, fn {m, _o, _mut} -> m == :relational end)
      assert length(negation) == 4
      assert_compiles(meta)
    end

    test "a bare `a === b` (no negation): the relaxation and the polarity flip both fire" do
      # Orthogonality off the negation path: StrictEquality (strictness) and Relational
      # (polarity) are distinct mutations, so both are offered on a plain equality.
      {meta, triples} = redundancy_triples("def f(a, b), do: a === b", @strict_negation)

      assert {:strict_equality, "a === b", "a == b"} in triples
      assert {:relational, "a === b", "a !== b"} in triples
      assert {:conditional, "a === b", "true"} in triples
      assert {:conditional, "a === b", "false"} in triples
      assert_compiles(meta)
    end

    test "a body `!!x` / `not not x`: the inner negation strip is suppressed" do
      for {src, stripped} <- [{"!!x", "!x"}, {"not not x", "not x"}] do
        {meta, triples} = redundancy_triples("def f(x), do: #{src}", @negation)

        # Both strips are the identical single-negation, and Conditional on the inner
        # duplicates the outer's true/false — so only one strip and one pair survive.
        assert triples == [
                 {:conditional, src, "true"},
                 {:conditional, src, "false"},
                 {:logical, src, stripped}
               ]

        assert_compiles(meta)
      end
    end

    test "a mixed `not !x` is NOT collapsed (the two strips can differ on a non-boolean)" do
      {meta, triples} = redundancy_triples("def f(x), do: not !x", [Mutare.Mutators.Logical])

      # `not x` (inner strip) raises on a non-boolean where `!x` (outer strip) coerces, so
      # the two are not equivalent — both negations stay offered.
      assert {:logical, "!x", "x"} in triples
      assert {:logical, "not (!x)", "!x"} in triples
      assert length(triples) == 2
      assert_compiles(meta)
    end

    test "a guard `not not x`: the inner strip is suppressed there too" do
      {meta, triples} =
        redundancy_triples(
          """
          def f(x) when not not x, do: :ok
          def f(_x), do: :no
          """,
          @negation
        )

      negation = Enum.filter(triples, fn {m, _o, _mut} -> m in [:conditional, :logical] end)

      assert negation == [
               {:conditional, "not not x", "true"},
               {:conditional, "not not x", "false"},
               {:logical, "not not x", "not x"}
             ]

      assert_compiles(meta)
    end

    test "a body `(bool) and (..)`: the connective's `false` is suppressed (≡ forcing left false)" do
      {meta, triples} = redundancy_triples("def f(a, b), do: a > 0 and b > 0", @connective)

      # Conditional forcing the whole `and` to false ≡ forcing the left `a > 0` to false (the
      # false left short-circuits the node), so the connective-node `false` is dropped. Its
      # `true`, Logical's `or`, and the operands' own true/false all stay — including
      # `a > 0 → false`, the survivor the dropped mutant was identical to.
      assert {:conditional, "a > 0 and b > 0", "true"} in triples
      refute {:conditional, "a > 0 and b > 0", "false"} in triples
      assert {:logical, "a > 0 and b > 0", "a > 0 or b > 0"} in triples
      assert {:conditional, "a > 0", "false"} in triples
      assert_compiles(meta)
    end

    test "a body `(bool) or (..)`: the connective's `true` is suppressed (≡ forcing left true)" do
      {meta, triples} = redundancy_triples("def f(a, b), do: a > 0 or b > 0", @connective)

      # The `or` mirror: `(L or R) → true` ≡ `L → true`, so the node's `true` goes and its
      # `false` stays.
      assert {:conditional, "a > 0 or b > 0", "false"} in triples
      refute {:conditional, "a > 0 or b > 0", "true"} in triples
      assert {:logical, "a > 0 or b > 0", "a > 0 and b > 0"} in triples
      assert_compiles(meta)
    end

    test "a body `(bool) && (..)`: the connective's `false` is suppressed too (short-circuit)" do
      {meta, triples} = redundancy_triples("def f(a, b), do: a == 0 && b == 0", @connective)

      # `&&` short-circuits like `and` for a boolean left, so the same drop applies — and `&&`
      # is body-only (guard-illegal), exercised only here.
      assert {:conditional, "a == 0 && b == 0", "true"} in triples
      refute {:conditional, "a == 0 && b == 0", "false"} in triples
      assert {:logical, "a == 0 && b == 0", "a == 0 || b == 0"} in triples
      assert_compiles(meta)
    end

    test "a body `(bool) || (..)`: the connective's `true` is suppressed too (short-circuit)" do
      {meta, triples} = redundancy_triples("def f(a, b), do: a == 0 || b == 0", @connective)

      # The `||` mirror of `&&`: `(L || R) → true` ≡ `L → true`, so the node's `true` is
      # dropped and its `false` stays. `||`, like `&&`, is body-only (guard-illegal).
      assert {:conditional, "a == 0 || b == 0", "false"} in triples
      refute {:conditional, "a == 0 || b == 0", "true"} in triples
      assert {:logical, "a == 0 || b == 0", "a == 0 && b == 0"} in triples
      assert_compiles(meta)
    end

    test "a connective with a NON-boolean-op left keeps both constants (no subsuming sibling)" do
      {meta, triples} = redundancy_triples("def f(a, b), do: is_binary(a) and b > 0", @connective)

      # `is_binary(a)` is a call, not a boolean op, so there is no `is_binary(a) → false`
      # Conditional mutant; the connective's `→ false` is the only way to force it false (and
      # is distinct — forcing the left false would still evaluate `is_binary(a)`). Both stay.
      assert {:conditional, "is_binary(a) and b > 0", "true"} in triples
      assert {:conditional, "is_binary(a) and b > 0", "false"} in triples
      assert_compiles(meta)
    end

    test "a connective of bare variables keeps both constants (a var is not a boolean op)" do
      {_meta, triples} = redundancy_triples("def f(a, b), do: a and b", @connective)

      assert {:conditional, "a and b", "true"} in triples
      assert {:conditional, "a and b", "false"} in triples
    end

    test "chained connectives each drop their own redundant constant (scales with depth)" do
      {meta, triples} =
        redundancy_triples("def f(a, b, c), do: a > 0 and b > 0 and c > 0", @connective)

      # Parses as `(a > 0 and b > 0) and c > 0`: the inner `and` (left `a > 0`) and the outer
      # `and` (left the inner `and`, itself a boolean op) each drop their `false`.
      refute {:conditional, "a > 0 and b > 0", "false"} in triples
      refute {:conditional, "a > 0 and b > 0 and c > 0", "false"} in triples
      assert {:conditional, "a > 0 and b > 0", "true"} in triples
      assert {:conditional, "a > 0 and b > 0 and c > 0", "true"} in triples
      assert_compiles(meta)
    end

    test "a guard `(bool) and (..)`: the connective's `false` is suppressed there too" do
      {meta, triples} =
        redundancy_triples(
          """
          def f(a, b) when a > 0 and b > 0, do: :ok
          def f(_a, _b), do: :no
          """,
          @connective
        )

      conn = Enum.filter(triples, fn {m, _o, _mut} -> m in [:conditional, :logical] end)

      assert {:conditional, "a > 0 and b > 0", "true"} in conn
      refute {:conditional, "a > 0 and b > 0", "false"} in conn
      assert {:logical, "a > 0 and b > 0", "a > 0 or b > 0"} in conn
      assert {:conditional, "a > 0", "false"} in conn
      assert_compiles(meta)
    end

    test "a guard `(bool) or (..)`: the connective's `true` is suppressed there too" do
      {meta, triples} =
        redundancy_triples(
          """
          def f(a, b) when a > 0 or b > 0, do: :ok
          def f(_a, _b), do: :no
          """,
          @connective
        )

      conn = Enum.filter(triples, fn {m, _o, _mut} -> m in [:conditional, :logical] end)

      # The guard `or` mirror of guard `and`: the node's `true` goes, its `false` stays, and
      # `a > 0 → true` (the survivor it duplicated) remains.
      assert {:conditional, "a > 0 or b > 0", "false"} in conn
      refute {:conditional, "a > 0 or b > 0", "true"} in conn
      assert {:logical, "a > 0 or b > 0", "a > 0 and b > 0"} in conn
      assert {:conditional, "a > 0", "true"} in conn
      assert_compiles(meta)
    end
  end

  # Transform a `def` body with the membership-relevant families and return the
  # `{mutator, original_code, mutated_code}` triples (relational/conditional/logical),
  # alongside the metamutant source so the caller can assert it compiles.
  defp membership_triples(body), do: redundancy_triples(body, @membership)

  # The same, parameterised by the mutator set — for the equivalent-sibling suppression
  # tests, which exercise Logical/List/Conditional combinations.
  defp redundancy_triples(body, mutators) do
    source = "defmodule M do\n  #{String.trim_trailing(body)}\nend\n"

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: mutators)

    triples = for s <- sites, do: {s.mutator, s.original_code, s.mutated_code}
    {meta, triples}
  end
end
