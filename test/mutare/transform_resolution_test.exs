defmodule Mutare.TransformResolutionTest do
  # Call resolution & delivery: alias/import/Erlang-atom resolution and the pipe-aware,
  # arity-changing call families (CollectionArity, ModeSwap, Numeric, String*, CallRemoval,
  # DefaultDrop, MapKeyword, MapSet) routed through it. Split from transform_test.exs.
  # `async: false` — the import-resolution tests capture the global `:stderr` device
  # (`assert_compile_error`) to assert on compile diagnostics.
  use ExUnit.Case, async: false

  alias Mutare.Site

  describe "CollectionArity (pipe-aware, arity-changing Enum mutations)" do
    test "non-piped: drops the comparator/predicate, and compiles" do
      assert {"Enum.sort(xs, & &1)", "Enum.reverse(xs)"} in arity_sites("""
             defmodule A do
               def f(xs), do: Enum.sort(xs, & &1)
             end
             """)

      assert {"Enum.count(xs, p)", "Enum.count(xs)"} in arity_sites("""
             defmodule A do
               def f(xs, p), do: Enum.count(xs, p)
             end
             """)
    end

    test "piped sort/2: the comparator is dropped (the fix), and the metamutant compiles" do
      # The naive node-local version mis-mutated this to Enum.reverse(:desc); the
      # pipe-aware path sees effective arity 2 and drops the comparator.
      sites =
        arity_sites("""
        defmodule A do
          def f(xs), do: xs |> Enum.sort(:desc)
        end
        """)

      assert {"Enum.sort(:desc)", "Enum.reverse()"} in sites
    end

    test "piped count_until/3 drops the predicate but keeps the limit, and compiles" do
      sites =
        arity_sites("""
        defmodule A do
          def f(xs, fun, lim), do: xs |> Enum.count_until(fun, lim)
        end
        """)

      assert {"Enum.count_until(fun, lim)", "Enum.count_until(lim)"} in sites
    end

    test "chained pipes with arity-changing stages compile" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule A do
            def f(xs, key), do: xs |> Enum.sort_by(key) |> Enum.reverse() |> Enum.join(",")
          end
          """,
          mutators: [Mutare.Mutators.CollectionArity]
        )

      assert Enum.any?(sites, &(&1.mutator == :collection_arity))
      assert_compiles(meta)
    end

    test "reverse/2 (reverse(list, tail)) is never mutated, piped or not" do
      assert [] ==
               arity_sites("""
               defmodule A do
                 def f(xs, t), do: Enum.reverse(xs, t)
                 def g(xs, t), do: xs |> Enum.reverse(t)
               end
               """)
    end

    test "Access.get_and_update/3 collapses to Access.get/2, dropping the update fun, and compiles" do
      assert {"Access.get_and_update(d, k, f)", "Access.get(d, k)"} in arity_sites("""
             defmodule A do
               def f(d, k, f), do: Access.get_and_update(d, k, f)
             end
             """)
    end

    test "piped Access.get_and_update keeps the container + key, dropping the update fun" do
      # `d |> Access.get_and_update(k, f)` reaches the mutator as a 2-arg stage; the
      # pipe-aware path sees effective arity 3 and keeps effective indices 0 (the piped
      # container) and 1 (the key), so the mutant is `d |> Access.get(k)`.
      assert {"Access.get_and_update(k, f)", "Access.get(k)"} in arity_sites("""
             defmodule A do
               def f(d, k, f), do: d |> Access.get_and_update(k, f)
             end
             """)
    end
  end

  describe "ModeSwap (pipe-aware mode/unit atom swaps)" do
    test "swaps the truncate precision in place, records the bare swap, and compiles" do
      sites =
        mode_sites("""
        defmodule M do
          def at(dt), do: DateTime.truncate(dt, :second)
        end
        """)

      assert {"DateTime.truncate(dt, :second)", "DateTime.truncate(dt, :millisecond)"} in sites
    end

    test "piped truncate: the precision is the lone visible arg, and compiles" do
      # The naive node-local view would misread the unit's position; the pipe-aware
      # path sees effective arity 2 and swaps the visible arg 0.
      sites =
        mode_sites("""
        defmodule M do
          def at(dt), do: dt |> DateTime.truncate(:second)
        end
        """)

      assert {"DateTime.truncate(:second)", "DateTime.truncate(:millisecond)"} in sites
    end

    test "calendar unit and Unicode case mode mutate, and compile together" do
      sites =
        mode_sites("""
        defmodule M do
          def later(dt, n), do: DateTime.add(dt, n, :minute)
          def shout(s), do: String.upcase(s, :turkic)
        end
        """)

      assert {"DateTime.add(dt, n, :minute)", "DateTime.add(dt, n, :second)"} in sites
      assert {"DateTime.add(dt, n, :minute)", "DateTime.add(dt, n, :hour)"} in sites
      assert {"String.upcase(s, :turkic)", "String.upcase(s, :default)"} in sites
    end

    test "overlap resolution drops the redundant AtomLiteral on a swapped mode atom, not elsewhere" do
      # Both families active. `:second` is a swappable precision (ModeSwap's call rewrite
      # covers it, so the diff-derived `Overlap` pass prunes the redundant AtomLiteral
      # leaf); `:tag` is a plain value atom (non-convention, so AtomLiteral owns it);
      # `:weird` is an invalid precision ModeSwap can't swap (no covering footprint →
      # AtomLiteral still fires).
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def at(dt), do: {DateTime.truncate(dt, :second), :tag}
            def bad(dt), do: DateTime.truncate(dt, :weird)
          end
          """,
          mutators: [Mutare.Mutators.ModeSwap, Mutare.Mutators.AtomLiteral]
        )

      by = fn mutator -> for s <- sites, s.mutator == mutator, do: s.original_code end

      # ModeSwap swapped the precision (its site records the whole call); the redundant
      # AtomLiteral mutant on the :second leaf was pruned by `Overlap`.
      assert "DateTime.truncate(dt, :second)" in by.(:mode_swap)
      refute ":second" in by.(:atom)

      # AtomLiteral still fires where no ModeSwap swap covers — a plain value, and an
      # atom ModeSwap produced no swap for.
      assert ":tag" in by.(:atom)
      assert ":weird" in by.(:atom)
    end

    test "swaps each shift duration unit key in place, records the swaps, and compiles" do
      sites =
        mode_sites("""
        defmodule M do
          def soon(dt), do: DateTime.shift(dt, minute: 10, day: -1)
          def t(t), do: Time.shift(t, hour: 1)
          def d(d), do: Date.shift(d, week: 2)
        end
        """)

      assert {"DateTime.shift(dt, minute: 10, day: -1)",
              "DateTime.shift(dt, second: 10, day: -1)"} in sites

      assert {"DateTime.shift(dt, minute: 10, day: -1)",
              "DateTime.shift(dt, minute: 10, week: -1)"} in sites

      # Time uses the time-only ladder (no :day to escape to).
      assert {"Time.shift(t, hour: 1)", "Time.shift(t, minute: 1)"} in sites

      # Date uses the date-only ladder — `week:` swaps to `day:`/`month:`, never a time unit.
      assert {"Date.shift(d, week: 2)", "Date.shift(d, day: 2)"} in sites
      assert {"Date.shift(d, week: 2)", "Date.shift(d, month: 2)"} in sites
    end

    test "call_option_keys is not a ModeSwap policy" do
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule M do\n  def soon(dt), do: DateTime.shift(dt, minute: 10)\nend\n",
          mutators: [{Mutare.Mutators.ModeSwap, call_option_keys: false}]
        )

      mutations = for site <- sites, site.mutator == :mode_swap, do: site.mutated_code
      assert "DateTime.shift(dt, second: 10)" in mutations
      assert "DateTime.shift(dt, hour: 10)" in mutations
    end

    test "a swapped shift unit key drops the redundant AtomLiteral, but Literal still mutates the amount" do
      # ModeSwap rewrites the call swapping the `minute:` key, so `Overlap` prunes the
      # redundant AtomLiteral on that key (it'd raise as `:mutare:`). The amount is a
      # different node ModeSwap leaves untouched, so Literal still mutates it.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def soon(dt), do: DateTime.shift(dt, minute: 10)
          end
          """,
          mutators: [
            Mutare.Mutators.ModeSwap,
            Mutare.Mutators.AtomLiteral,
            Mutare.Mutators.Literal
          ]
        )

      mode_swaps = for s <- sites, s.mutator == :mode_swap, do: s.mutated_code
      literals = for s <- sites, s.mutator == :literal, do: {s.original_code, s.mutated_code}

      # ModeSwap swaps the unit key both ways…
      assert "DateTime.shift(dt, second: 10)" in mode_swaps
      assert "DateTime.shift(dt, hour: 10)" in mode_swaps
      # …so the redundant AtomLiteral on the `minute:` key is pruned.
      assert Enum.filter(sites, &(&1.mutator == :atom)) == []
      # The amount stays runtime data — Literal still mutates it.
      assert {"10", "11"} in literals
      assert {"10", "9"} in literals
    end

    test "overlap is per-key: an excluded unit beside a swappable one keeps its AtomLiteral" do
      # `:minute` is swappable; `:microsecond` is excluded from the duration ladder, so
      # ModeSwap produces no swap for it → no covering footprint → AtomLiteral still fires
      # on the `microsecond:` key. The fix for the old blanket "own all keys" bug, which
      # suppressed `microsecond:` only when a swappable sibling shared the list.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def a(dt), do: DateTime.shift(dt, minute: 10, microsecond: {5, 6})
          end
          """,
          mutators: [Mutare.Mutators.ModeSwap, Mutare.Mutators.AtomLiteral]
        )

      atoms = for s <- sites, s.mutator == :atom, do: s.original_code
      mode_swaps = for s <- sites, s.mutator == :mode_swap, do: s.mutated_code

      # ModeSwap swaps only the `minute:` key.
      assert "DateTime.shift(dt, second: 10, microsecond: {5, 6})" in mode_swaps
      assert "DateTime.shift(dt, hour: 10, microsecond: {5, 6})" in mode_swaps

      # The swapped `minute:` key's redundant AtomLiteral is pruned…
      refute "minute:" in atoms
      # …but the excluded `microsecond:` key keeps its AtomLiteral (consistent with the
      # lone case below — not decided by a sibling).
      assert "microsecond:" in atoms
    end

    test "overlap consistency: a lone excluded unit also keeps its AtomLiteral" do
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def a(dt), do: DateTime.shift(dt, microsecond: {5, 6})
          end
          """,
          mutators: [Mutare.Mutators.ModeSwap, Mutare.Mutators.AtomLiteral]
        )

      atoms = for s <- sites, s.mutator == :atom, do: s.original_code
      assert "microsecond:" in atoms
      assert Enum.filter(sites, &(&1.mutator == :mode_swap)) == []
    end

    test "OperandSwap on an infix operator does not prune the Arithmetic/List sibling" do
      # `a - b` → `b - a` (OperandSwap) changes the *argument list* `[a, b]`, which Sourceror
      # ranges identically to the whole `a - b` node. That whole-host footprint must NOT be
      # treated as covering, or the operator-swap sibling (same host range) would be dropped.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(a, b), do: a - b
            def g(a, b), do: a ++ b
          end
          """,
          mutators: [
            Mutare.Mutators.OperandSwap,
            Mutare.Mutators.Arithmetic,
            Mutare.Mutators.List
          ]
        )

      pairs = for s <- sites, do: {s.mutator, s.original_code, s.mutated_code}

      # Both the operand swap AND the operator swap survive on the same infix node.
      assert {:operand_swap, "a - b", "b - a"} in pairs
      assert {:arithmetic, "a - b", "a + b"} in pairs
      assert {:operand_swap, "a ++ b", "b ++ a"} in pairs
      assert {:list, "a ++ b", "a -- b"} in pairs
    end

    test "imported (qualify) ModeSwap stays minimal and still covers the mode atom" do
      # `import DateTime, only: [truncate: 2]` is selective, so `Calls` would normally
      # *qualify* a rewritten call. But a value-only swap keeps the same name/arity, so the
      # mutant stays bare (`truncate(dt, :millisecond)`) rather than requalifying the whole
      # call — which keeps the diff minimal AND keeps it a single-node change, so `Overlap`
      # still recognises the swap covers the `:second` leaf and prunes the redundant
      # AtomLiteral `:mutare` (which `owned_args/2` used to suppress).
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            import DateTime, only: [truncate: 2]
            def f(dt), do: truncate(dt, :second)
          end
          """,
          mutators: [Mutare.Mutators.ModeSwap, Mutare.Mutators.AtomLiteral]
        )

      pairs = for s <- sites, do: {s.mutator, s.original_code, s.mutated_code}

      # Minimal, bare swap — not the requalified `Elixir.DateTime.truncate(...)`.
      assert {:mode_swap, "truncate(dt, :second)", "truncate(dt, :millisecond)"} in pairs
      # The redundant leaf mutant is gone.
      assert Enum.filter(sites, &(&1.mutator == :atom)) == []
    end

    test "a piped one-arg DefaultDrop does not prune the default's value mutant" do
      # `xs |> List.first(0)` has one *visible* arg, so DefaultDrop's drop turns `[0]` into
      # `[]`. Sourceror ranges the one-element list `[0]` identically to `0`, but dropping the
      # arg is orthogonal to mutating its value — a list-valued footprint is never covering, so
      # `Literal 0` (and `AtomLiteral :none` below) survives alongside the drop.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(xs), do: xs |> List.first(0)
            def g(ys), do: ys |> List.last(:none)
          end
          """,
          mutators: [
            Mutare.Mutators.DefaultDrop,
            Mutare.Mutators.Literal,
            Mutare.Mutators.AtomLiteral
          ]
        )

      pairs = for s <- sites, do: {s.mutator, s.original_code, s.mutated_code}

      assert {:default_drop, "List.first(0)", "List.first()"} in pairs
      assert {:literal, "0", "1"} in pairs
      assert {:default_drop, "List.last(:none)", "List.last()"} in pairs
      assert {:atom, ":none", ":mutare"} in pairs
    end

    test "StringCall's equivalent? -> Elixir.Kernel.== is non-covering: it prunes no leaf" do
      # `String.equivalent?(a, "x")` -> `Elixir.Kernel.==(a, "x")` rewrites the callee's *module*
      # (`String` -> `Elixir.Kernel`) *and* its fun (`equivalent?` -> `==`) while reusing both args,
      # so the two changes climb to their common parent — the callee's `[mod, fun]` list, which
      # carries no nid → *non-covering*. (A bare `a == b` would instead be covering-yet-inert; the
      # absolute `Elixir.Kernel.==` makes it a nid-less list footprint.) Either way it prunes
      # nothing: the reused `"x"` literal keeps both its StringLiteral mutants alongside the rewrite.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(a), do: String.equivalent?(a, "x")
          end
          """,
          mutators: [Mutare.Mutators.StringCall, Mutare.Mutators.StringLiteral]
        )

      pairs = for s <- sites, do: {s.mutator, s.original_code, s.mutated_code}

      assert {:string_call, "String.equivalent?(a, \"x\")", "Elixir.Kernel.==(a, \"x\")"} in pairs
      assert {:string, "\"x\"", "\"\""} in pairs
      assert {:string, "\"x\"", "\"mutare\""} in pairs
    end
  end

  describe "Numeric (complementary Kernel/Float numeric swaps)" do
    test "swaps bare Kernel min/max and round/ceil, records the swaps, and compiles" do
      sites =
        numeric_sites("""
        defmodule M do
          def clamp(x, lo, hi), do: min(max(x, lo), hi)
          def near(x), do: round(x)
          def up(x), do: ceil(x)
        end
        """)

      assert {"max(x, lo)", "min(x, lo)"} in sites
      assert {"min(max(x, lo), hi)", "max(max(x, lo), hi)"} in sites
      assert {"round(x)", "trunc(x)"} in sites
      assert {"ceil(x)", "floor(x)"} in sites
    end

    test "piped Kernel call: effective arity sees the true arity, and compiles" do
      # `x |> max(0)` reaches the mutator as a 1-arg node; the pipe-aware path reads
      # effective arity 2 and offers the min/max swap on the visible stage.
      sites =
        numeric_sites("""
        defmodule M do
          def floor_zero(x), do: x |> max(0)
          def whole(x), do: x |> floor()
        end
        """)

      assert {"max(0)", "min(0)"} in sites
      assert {"floor()", "ceil()"} in sites
    end

    test "swaps Float.ceil ↔ Float.floor (arity-blind), and compiles" do
      source = """
      defmodule F do
        def up(x), do: Float.ceil(x, 2)
        def down(x), do: Float.floor(x)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.Numeric])

      pairs = for s <- sites, s.mutator == :numeric, do: {s.original_code, s.mutated_code}
      assert {"Float.ceil(x, 2)", "Float.floor(x, 2)"} in pairs
      assert {"Float.floor(x)", "Float.ceil(x)"} in pairs
      assert_compiles(meta)
    end

    test "swaps Float.max_finite ↔ Float.min_finite (the /0 extreme pair), and compiles" do
      source = """
      defmodule F do
        def hi, do: Float.max_finite()
        def lo, do: Float.min_finite()
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.Numeric])

      pairs = for s <- sites, s.mutator == :numeric, do: {s.original_code, s.mutated_code}
      assert {"Float.max_finite()", "Float.min_finite()"} in pairs
      assert {"Float.min_finite()", "Float.max_finite()"} in pairs
      assert_compiles(meta)
    end

    test "swaps Kernel-qualified calls (arity-blind, like the Float pair), and compiles" do
      sites =
        numeric_sites("""
        defmodule M do
          def clamp(x, lo, hi), do: Kernel.min(Kernel.max(x, lo), hi)
          def near(x), do: Kernel.round(x)
        end
        """)

      assert {"Kernel.max(x, lo)", "Kernel.min(x, lo)"} in sites
      assert {"Kernel.round(x)", "Kernel.trunc(x)"} in sites
    end

    test "swaps a Kernel numeric call inside a guard via lifting, and compiles" do
      # `min`/`max`/`round`/… are guard-safe, so a swap is legal in a `when` and is
      # delivered by lifting the clause group.
      sites =
        numeric_sites("""
        defmodule G do
          def small?(x) when floor(x) < 10, do: true
          def small?(_), do: false
        end
        """)

      assert {"floor(x)", "ceil(x)"} in sites
    end
  end

  describe "alias resolution (aliased remote calls still mutate)" do
    test "an aliased Enum call mutates, and the diff keeps the alias" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias Enum, as: E
            def f(xs), do: E.filter(xs, & &1)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      # Recognised through the alias, and the mutant keeps `E.` (not `Enum.`).
      assert {"E.filter(xs, & &1)", "E.reject(xs, & &1)"} in pairs
      assert_compiles(meta)
    end

    test "an aliased String / Float call mutates through its family, keeping the alias" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias String, as: S
            alias Float, as: F
            def up(x), do: S.upcase(x)
            def down(x), do: F.ceil(x)
          end
          """,
          mutators: [Mutare.Mutators.StringCall, Mutare.Mutators.Numeric]
        )

      by = fn m -> for s <- sites, s.mutator == m, do: {s.original_code, s.mutated_code} end
      assert {"S.upcase(x)", "S.downcase(x)"} in by.(:string_call)
      assert {"F.ceil(x)", "F.floor(x)"} in by.(:numeric)
      assert_compiles(meta)
    end

    test "aliasing a stdlib name to a local module is NOT matched (shadow is respected)" do
      # `alias MyApp.Enum` rebinds `Enum` to a local module, so `Enum.filter` must NOT be
      # treated as the stdlib Enum. (No compile here — MyApp.Enum is fictional; the point
      # is the *absence* of a Collection site.)
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias MyApp.Enum
            def f(xs), do: Enum.filter(xs, & &1)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      refute Enum.any?(sites, &(&1.mutator == :collection))
    end

    test "Integer routes through the same machinery — aliased matched, shadow respected" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            require Integer
            alias Integer, as: I
            def even?(n) when I.is_even(n), do: I.mod(n, 2)
          end
          """,
          mutators: [Mutare.Mutators.Integer]
        )

      pairs = for s <- sites, s.mutator == :integer, do: {s.original_code, s.mutated_code}
      # Recognised through the alias (guard swap is lifted), and the mutant keeps `I.`.
      assert {"I.is_even(n)", "I.is_odd(n)"} in pairs
      assert {"I.mod(n, 2)", "I.floor_div(n, 2)"} in pairs
      assert_compiles(meta)

      # A shadowing `alias MyApp.Integer` resolves away from stdlib — no Integer site.
      {_meta, shadow_sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias MyApp.Integer
            def f(a, b), do: Integer.mod(a, b)
          end
          """,
          mutators: [Mutare.Mutators.Integer]
        )

      refute Enum.any?(shadow_sites, &(&1.mutator == :integer))
    end

    test "a fully-qualified `Elixir.`-prefixed call mutates, keeping the prefix in the diff" do
      # The easy case the alias machinery used to skip entirely. The mutant keeps the written
      # `Elixir.String.` (minimal diff), and the metamutant compiles.
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def first(s), do: Elixir.String.first(s)
          end
          """,
          mutators: [Mutare.Mutators.StringCall]
        )

      pairs = for s <- sites, s.mutator == :string_call, do: {s.original_code, s.mutated_code}
      assert {"Elixir.String.first(s)", "Elixir.String.last(s)"} in pairs
      assert_compiles(meta)
    end

    test "a `&Elixir.Mod.fun/N` capture of a fully-qualified call mutates too" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def ref, do: &Elixir.String.first/1
          end
          """,
          mutators: [Mutare.Mutators.StringCall]
        )

      pairs = for s <- sites, s.mutator == :string_call, do: {s.original_code, s.mutated_code}
      assert {"&Elixir.String.first/1", "&Elixir.String.last/1"} in pairs
      assert_compiles(meta)
    end

    test "the Elixir prefix is alias-proof: it mutates while a shadowed bare call does not" do
      # `alias Wrong, as: String` shadows the bare name, so `String.upcase` is NOT the stdlib
      # `String` and must not mutate — but `Elixir.String.first` is absolute and still must.
      # (No compile — `Wrong` is fictional; the point is the asymmetry of the two sites.)
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias Wrong, as: String
            def first(s), do: Elixir.String.first(s)
            def up(s), do: String.upcase(s)
          end
          """,
          mutators: [Mutare.Mutators.StringCall]
        )

      pairs = for s <- sites, s.mutator == :string_call, do: {s.original_code, s.mutated_code}
      assert {"Elixir.String.first(s)", "Elixir.String.last(s)"} in pairs
      refute Enum.any?(pairs, fn {orig, _} -> orig == "String.upcase(s)" end)
    end

    test "a call through an alias of the root namespace mutates like a direct one" do
      # `alias Elixir, as: E` aliases the root namespace, so `E.String.first` is the stdlib
      # `String` reached through the alias. The combined key `[Elixir, :String]` must normalize
      # to `[:String]` — else the call would match no swap table and never mutate.
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias Elixir, as: E
            def first(s), do: E.String.first(s)
          end
          """,
          mutators: [Mutare.Mutators.StringCall]
        )

      pairs = for s <- sites, s.mutator == :string_call, do: {s.original_code, s.mutated_code}
      assert {"E.String.first(s)", "E.String.last(s)"} in pairs
      assert_compiles(meta)
    end

    test "a call through a grouped alias of the root namespace mutates" do
      # `alias Elixir.{String}` assembles the child key `[Elixir, :String]`, which must normalize
      # to `[:String]` so the bare `String.first` resolves to the stdlib module.
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias Elixir.{String}
            def first(s), do: String.first(s)
          end
          """,
          mutators: [Mutare.Mutators.StringCall]
        )

      pairs = for s <- sites, s.mutator == :string_call, do: {s.original_code, s.mutated_code}
      assert {"String.first(s)", "String.last(s)"} in pairs
      assert_compiles(meta)
    end
  end

  describe "import resolution (bare imported calls mutate)" do
    test "CallRemoval removes a bare imported transparent transform" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpRemoval do
            import Enum
            def f(xs), do: sort(xs)
          end
          """,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      pairs = for s <- sites, s.mutator == :call_removal, do: {s.original_code, s.mutated_code}
      assert {"sort(xs)", "xs"} in pairs
      assert_compiles(meta)
    end

    test "a whole-module import makes a bare call mutate, keeping it bare" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpWhole do
            import Enum
            def f(xs), do: reject(xs, & &1)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      # Whole import ⇒ the sibling `filter` is imported too, so the mutant stays bare.
      assert {"reject(xs, & &1)", "filter(xs, & &1)"} in pairs
      assert_compiles(meta)
    end

    test "a fully-qualified `import Elixir.Enum` resolves its bare calls" do
      # `resolve_path/2` is shared with the import pre-pass, so the `Elixir.`-prefix strip must
      # land `import Elixir.Enum` on the same `[:Enum]` key as a plain `import Enum` — else the
      # bare `reject` would carry `[:Elixir, :Enum]`, match no swap table, and be missed. This
      # guards the import path against a future `resolve_path` refactor (the call path has its
      # own tests above).
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpQualified do
            import Elixir.Enum
            def f(xs), do: reject(xs, & &1)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      assert {"reject(xs, & &1)", "filter(xs, & &1)"} in pairs
      assert_compiles(meta)
    end

    test "a selective import qualifies the mutant (the sibling may not be imported)" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpOnly do
            import Enum, only: [reject: 2]
            def f(xs), do: reject(xs, & &1)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      # `filter/2` isn't imported, so the swap qualifies — and the qualifier is alias-proof
      # (`Elixir.`-prefixed), so it always names the real module, compile-safe.
      assert {"reject(xs, & &1)", "Elixir.Enum.filter(xs, & &1)"} in pairs
      assert_compiles(meta)
    end

    test "a qualified mutant bypasses a conflicting alias on the import's name" do
      # `import Enum, only: [reject: 2]` captures the real Enum; a *later* `alias String, as:
      # Enum` rebinds the name `Enum`. The mutant must call the real `Enum.filter` — a bare
      # `Enum.filter` would compile as `String.filter/2` (which doesn't exist). The
      # `Elixir.`-prefixed qualifier bypasses the alias; `assert_compiles` proves it (the
      # metamutant keeps the alias in scope).
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpAliasClash do
            import Enum, only: [reject: 2]
            alias String, as: Enum
            def f(xs, fun), do: reject(xs, fun)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      assert {"reject(xs, fun)", "Elixir.Enum.filter(xs, fun)"} in pairs
      assert_compiles(meta)
    end

    test "a whole import alongside another import qualifies, avoiding an ambiguous bare sibling" do
      # `import Stream, except: [filter: 2]` leaves `Stream.reject` in scope; a bare swap of the
      # whole-imported `filter`→`reject` would be ambiguous (Stream's *and* Enum's) and fail to
      # compile. Qualifying to the real `Enum.reject` keeps it sound — `assert_compiles` proves
      # there is no ambiguity.
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpMulti do
            import Stream, except: [filter: 2]
            import Enum
            def f(xs, fun), do: filter(xs, fun)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      assert {"filter(xs, fun)", "Elixir.Enum.reject(xs, fun)"} in pairs
      assert_compiles(meta)
    end

    test "a hidden except-plus-replacement import poisons instead of silently mis-resolving" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule HiddenImportReplacement do
            def filter(xs, fun), do: Enum.map(xs, fun)

            defmacro __using__(_) do
              quote do
                import Enum, except: [filter: 2]
                import HiddenImportReplacement, only: [filter: 2]
              end
            end
          end

          defmodule ImpHiddenReplacement do
            import Enum
            use HiddenImportReplacement

            def f(xs, fun), do: filter(xs, fun)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      assert [%{mutator: :collection, original_code: "filter(xs, fun)"} = site] = sites
      assert meta =~ "import Elixir.Enum, only: [filter: 2]"

      stderr =
        assert_compile_error(
          meta,
          # Elixir <1.20: "filter/2 imported from both Enum and HiddenImportReplacement";
          # Elixir 1.20+: "conflicting filter/2 import from modules Enum and HiddenImportReplacement".
          ["filter/2", "Enum and HiddenImportReplacement"],
          "lib/hidden_import_replacement.ex"
        )

      assert Mutare.Poison.ids(stderr, %{"lib/hidden_import_replacement.ex" => meta}) ==
               MapSet.new([site.id])
    end

    test "the import witness also protects lifted guard mutants" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule HiddenIntegerReplacement do
            defmacro is_even(n), do: quote(do: is_integer(unquote(n)))

            defmacro __using__(_) do
              quote do
                import Integer, except: [is_even: 1]
                import HiddenIntegerReplacement, only: [is_even: 1]
              end
            end
          end

          defmodule ImpHiddenGuardReplacement do
            import Integer
            use HiddenIntegerReplacement

            def f(n) when is_even(n), do: true
            def f(_), do: false
          end
          """,
          mutators: [Mutare.Mutators.Integer]
        )

      assert [%{kind: :lifted, mutator: :integer, original_code: "is_even(n)"} = site] =
               Enum.filter(sites, &(&1.mutator == :integer))

      assert meta =~ "import Elixir.Integer, only: [is_even: 1]"

      stderr =
        assert_compile_error(
          meta,
          # Elixir <1.20: "is_even/1 imported from both Integer and HiddenIntegerReplacement";
          # Elixir 1.20+: "conflicting is_even/1 import from modules Integer and HiddenIntegerReplacement".
          ["is_even/1", "Integer and HiddenIntegerReplacement"],
          "lib/hidden_integer_replacement.ex"
        )

      assert Mutare.Poison.ids(stderr, %{"lib/hidden_integer_replacement.ex" => meta}) ==
               MapSet.new([site.id])
    end

    test "a same-named local function with no import is not mutated" do
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpLocal do
            def reject(a, b), do: {a, b}
            def f(xs), do: reject(xs, 1)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      refute Enum.any?(sites, &(&1.mutator == :collection))
    end

    test "a different-arity local does not shadow a sole whole import (resolves by arity)" do
      # `reject/1` is local; the call is `reject/2`, which is Enum's (different arity, no
      # conflict). The swap to `filter/2` names Enum's (bare, sole import) and compiles — the
      # incidental local `reject/1` never enters resolution.
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpLocalArity do
            import Enum
            def reject(a), do: a
            def f(xs, fun), do: reject(xs, fun)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      assert {"reject(xs, fun)", "filter(xs, fun)"} in pairs
      assert_compiles(meta)
    end

    test "a bare imported guard macro mutates via lifting and compiles" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpGuard do
            import Integer
            def f(n) when is_even(n), do: n
            def f(_), do: 0
          end
          """,
          mutators: [Mutare.Mutators.Integer]
        )

      site = Enum.find(sites, &(&1.mutator == :integer))
      assert %Site{kind: :lifted, original_code: "is_even(n)", mutated_code: "is_odd(n)"} = site
      assert_compiles(meta)
    end

    test "a bare Kernel call displaced by `import Kernel, except:` is left alone" do
      # `abs` is excepted from Kernel, so a bare `abs` here is some other module's — not the
      # Kernel `abs/1` CallRemoval assumes. (No compile — the other module is fictional; the
      # point is the *absence* of a removal site.)
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule ImpDisplaced do
            import Kernel, except: [abs: 1]
            import MyAbs
            def f(x), do: abs(x)
          end
          """,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      refute Enum.any?(sites, &(&1.mutator == :call_removal))
    end
  end

  describe "atom-module (Erlang) resolution via alias / import" do
    test "an aliased Erlang module mutates through its family, keeping the alias" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias :string, as: S
            def f(x), do: S.uppercase(x)
          end
          """,
          mutators: [Mutare.Mutators.StringCall]
        )

      pairs = for s <- sites, s.mutator == :string_call, do: {s.original_code, s.mutated_code}
      assert {"S.uppercase(x)", "S.lowercase(x)"} in pairs
      assert_compiles(meta)
    end

    test "a bare imported Erlang call mutates (Math :math)" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            import :math
            def f(x), do: sin(x)
          end
          """,
          mutators: [Mutare.Mutators.Math]
        )

      pairs = for s <- sites, s.mutator == :math, do: {s.original_code, s.mutated_code}
      assert {"sin(x)", "cos(x)"} in pairs
      assert_compiles(meta)
    end

    test "a bare imported Erlang transparent transform is removed (CallRemoval :string)" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            import :string
            def f(s), do: trim(s)
          end
          """,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      pairs = for s <- sites, s.mutator == :call_removal, do: {s.original_code, s.mutated_code}
      assert {"trim(s)", "s"} in pairs
      assert_compiles(meta)
    end
  end

  describe "receiver-position calls (a chained dot-call's receiver is resolved & mutated)" do
    # The receiver of `recv.field` / `recv.fun(args)` is a runtime sub-expression when it is not a
    # module reference (`get_config().fetch(k)`, `Repo.get(...).name`), so a stdlib/aliased/imported
    # call sitting there must resolve and mutate like one written anywhere else. The *module side* of
    # an ordinary remote call (`Enum.filter(...)`'s `Enum`) stays opaque — the two split on whether
    # the receiver is a module reference (`Mutare.Transform.Resolve` clause #4 / `Analyze`'s
    # `descend_receiver/2`).

    test "a direct stdlib call in receiver position mutates, keeping the written receiver" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(x), do: Enum.filter(x, & &1).first
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      assert {"Enum.filter(x, & &1)", "Enum.reject(x, & &1)"} in pairs
      assert_compiles(meta)
    end

    test "an aliased call in receiver position resolves and mutates, keeping the alias" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias Enum, as: E
            def f(x), do: E.filter(x, & &1).first
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      # Resolved through the alias even though it sits in the receiver, and the mutant keeps `E.`.
      assert {"E.filter(x, & &1)", "E.reject(x, & &1)"} in pairs
      assert_compiles(meta)
    end

    test "a bare imported call in receiver position resolves and mutates" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            import Enum
            def f(x), do: filter(x, & &1).first
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      assert {"filter(x, & &1)", "reject(x, & &1)"} in pairs
      assert_compiles(meta)
    end

    test "a method-style receiver call mutates, and the spliced selector compiles in that position" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(xs, x), do: Enum.filter(xs, & &1).put(x)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      # The receiver mutates and the emitted `(case … end).put(x)` is legal Elixir.
      assert {"Enum.filter(xs, & &1)", "Enum.reject(xs, & &1)"} in pairs
      assert_compiles(meta)
    end

    test "the module side of a remote call stays opaque (the receiver split, not a blanket descent)" do
      # `descend_receiver/2` must NOT offer the module reference of an ordinary remote call to a
      # mutator: `Enum` in `Enum.filter(x).first` is the module side, never a value. AliasLiteral
      # (which mutates a module *value* like `apply(Foo, …)`) therefore produces no site here.
      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            def f(x), do: Enum.filter(x, & &1).first
          end
          """,
          mutators: [Mutare.Mutators.AliasLiteral]
        )

      assert sites == []
    end

    test "a known macro in receiver position is routed too (its :skip arg stays raw)" do
      source = """
      defmodule M do
        def f(q), do: :my_dsl.filter(q, 99).bar
      end
      """

      {_, skipped, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Literal],
          macro_routes: [{:my_dsl, :filter, :any, :skip}]
        )

      {_, control, _} =
        Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.Literal])

      # Walking the receiver carries the macro routing in too: the `99` in the `:skip` macro is
      # left raw even though the macro call is a receiver — while unregistered it mutates.
      assert Enum.map(skipped, & &1.mutator) == []
      assert Enum.any?(control, &(&1.mutator == :literal))
    end
  end

  describe "StringCall (complementary String call swaps)" do
    test "swaps a String call in place, records the bare swap, and compiles" do
      source = """
      defmodule S do
        def affix?(s), do: String.starts_with?(s, "x")
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringCall]
        )

      assert Enum.any?(sites, &(&1.mutator == :string_call))
      assert Enum.any?(sites, &(&1.mutated_code == ~s|String.ends_with?(s, "x")|))
      assert_compiles(meta)
    end

    test "swaps String.graphemes/codepoints and replace_leading/trailing, and compiles" do
      source = """
      defmodule S do
        def gs(s), do: String.graphemes(s)
        def rl(s), do: String.replace_leading(s, "0", "")
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringCall]
        )

      pairs = for s <- sites, s.mutator == :string_call, do: {s.original_code, s.mutated_code}
      assert {"String.graphemes(s)", "String.codepoints(s)"} in pairs

      assert {~s|String.replace_leading(s, "0", "")|, ~s|String.replace_trailing(s, "0", "")|} in pairs

      assert_compiles(meta)
    end

    test "an Erlang :string call node is offered, swapped, and compiles" do
      source = """
      defmodule S do
        def up(s), do: :string.uppercase(s)
        def down(s), do: s |> :string.lowercase()
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringCall]
        )

      pairs = for s <- sites, s.mutator == :string_call, do: {s.original_code, s.mutated_code}
      assert {":string.uppercase(s)", ":string.lowercase(s)"} in pairs
      # piped: the recorded stage is the bare LHS-less call
      assert {":string.lowercase()", ":string.uppercase()"} in pairs
      assert_compiles(meta)
    end

    test "String.equivalent? becomes raw ==, direct and piped, and compiles" do
      source = """
      defmodule S do
        def a?(a, b), do: String.equivalent?(a, b)
        def b?(a, b), do: a |> String.equivalent?(b)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringCall]
        )

      pairs = for s <- sites, s.mutator == :string_call, do: {s.original_code, s.mutated_code}
      assert {"String.equivalent?(a, b)", "Elixir.Kernel.==(a, b)"} in pairs
      # piped: the LHS-less stage; the |> feeds the left operand at runtime
      assert {"String.equivalent?(b)", "Elixir.Kernel.==(b)"} in pairs
      assert_compiles(meta)
    end
  end

  describe "StringByte (grapheme-aware String.length -> byte-level byte_size)" do
    test "narrows String.length, direct and piped, and compiles" do
      source = """
      defmodule S do
        def len(s), do: String.length(s)
        def plen(s), do: s |> String.length()
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringByte]
        )

      pairs = for s <- sites, s.mutator == :string_byte, do: {s.original_code, s.mutated_code}
      # Absolute-qualified so neither a local/selective-import byte_size nor a rebound Kernel
      # alias can shadow the swap.
      assert {"String.length(s)", "Elixir.Kernel.byte_size(s)"} in pairs
      # piped: the recorded stage is the LHS-less call; the |> feeds the left arg at runtime
      assert {"String.length()", "Elixir.Kernel.byte_size()"} in pairs
      assert_compiles(meta)
    end

    test "the absolute-qualified swap compiles even when byte_size is locally shadowed" do
      source = """
      defmodule S do
        import Kernel, except: [byte_size: 1]
        def byte_size(_), do: :local
        def len(s), do: String.length(s)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringByte]
        )

      assert {"String.length(s)", "Elixir.Kernel.byte_size(s)"} in for(
               s <- sites,
               s.mutator == :string_byte,
               do: {s.original_code, s.mutated_code}
             )

      assert_compiles(meta)
    end

    test "the absolute-qualified swap compiles even when the Kernel name is rebound" do
      # `alias String, as: Kernel` would make a plain `Kernel.byte_size` resolve to the
      # nonexistent `String.byte_size`; the absolute `Elixir.Kernel.byte_size` still works.
      source = """
      defmodule S do
        alias String, as: Kernel
        def len(s), do: String.length(s)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringByte]
        )

      assert Enum.any?(sites, &(&1.mutator == :string_byte))
      assert_compiles(meta)
    end

    test "matches an aliased String call and a shadowing alias is left alone" do
      source = """
      defmodule S do
        alias String, as: Str
        alias MyApp.String, as: Local
        def real(s), do: Str.length(s)
        def shadow(s), do: Local.length(s)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringByte]
        )

      pairs = for s <- sites, s.mutator == :string_byte, do: {s.original_code, s.mutated_code}
      # The aliased real String resolves and is narrowed (alias preserved in the diff source).
      assert {"Str.length(s)", "Elixir.Kernel.byte_size(s)"} in pairs
      # The shadowing `alias MyApp.String` resolves to the local module — not narrowed.
      refute Enum.any?(pairs, fn {orig, _} -> orig == "Local.length(s)" end)
      assert_compiles(meta)
    end

    test "is one-way: byte_size is not broadened back to String.length" do
      source = """
      defmodule S do
        def a(s), do: byte_size(s)
        def b(s), do: Kernel.byte_size(s)
      end
      """

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringByte]
        )

      assert [] == Enum.filter(sites, &(&1.mutator == :string_byte))
    end
  end

  describe "CallRemoval (transparent transform removal)" do
    test "non-piped removal returns the first arg; piped removal uses Elixir.Function.identity — both compile" do
      source = """
      defmodule R do
        def a(xs), do: Enum.sort(xs, :desc)
        def b(s), do: s |> String.trim() |> String.downcase()
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      pairs = for s <- sites, s.mutator == :call_removal, do: {s.original_code, s.mutated_code}
      # Non-piped: the whole transform collapses to its input.
      assert {"Enum.sort(xs, :desc)", "xs"} in pairs
      # Piped: each stage becomes a no-op the pipe feeds.
      assert {"String.trim()", "Elixir.Function.identity()"} in pairs
      assert {"String.downcase()", "Elixir.Function.identity()"} in pairs
      assert_compiles(meta)
    end

    test "String.slice removal returns the whole input and compiles" do
      source = """
      defmodule R do
        def a(s), do: String.slice(s, 1, 3)
        def b(s), do: s |> String.slice(1..3)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      pairs = for s <- sites, s.mutator == :call_removal, do: {s.original_code, s.mutated_code}
      assert {"String.slice(s, 1, 3)", "s"} in pairs
      assert {"String.slice(1..3)", "Elixir.Function.identity()"} in pairs
      assert_compiles(meta)
    end

    test "String.byte_slice removal returns the whole input and compiles" do
      source = """
      defmodule R do
        def a(s), do: String.byte_slice(s, 1, 3)
        def b(s), do: s |> String.byte_slice(1, 3)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      pairs = for s <- sites, s.mutator == :call_removal, do: {s.original_code, s.mutated_code}
      assert {"String.byte_slice(s, 1, 3)", "s"} in pairs
      assert {"String.byte_slice(1, 3)", "Elixir.Function.identity()"} in pairs
      assert_compiles(meta)
    end

    test "Map/Keyword/List key & element strippers are removed and compile" do
      source = """
      defmodule R do
        def a(m, k), do: Map.delete(m, k)
        def b(m, ks), do: Map.take(m, ks)
        def c(kw, k), do: Keyword.delete(kw, k)
        def d(xs, x), do: List.delete(xs, x)
        def e(xs), do: xs |> Map.drop([:a]) |> List.delete_at(0)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      pairs = for s <- sites, s.mutator == :call_removal, do: {s.original_code, s.mutated_code}
      assert {"Map.delete(m, k)", "m"} in pairs
      assert {"Map.take(m, ks)", "m"} in pairs
      assert {"Keyword.delete(kw, k)", "kw"} in pairs
      assert {"List.delete(xs, x)", "xs"} in pairs
      # Piped stages collapse to the no-op the pipe feeds.
      assert {"Map.drop([:a])", "Elixir.Function.identity()"} in pairs
      assert {"List.delete_at(0)", "Elixir.Function.identity()"} in pairs
      assert_compiles(meta)
    end

    test "map/filter are not removable" do
      source = """
      defmodule R do
        def f(xs), do: xs |> Enum.map(& &1) |> Enum.filter(& &1)
      end
      """

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      assert [] == Enum.filter(sites, &(&1.mutator == :call_removal))
    end

    test "the Kernel binary slicers collapse to the whole binary and compile" do
      source = """
      defmodule R do
        def a(b), do: binary_slice(b, 0, 5)
        def c(b), do: b |> binary_slice(0..4)
        def d(b), do: binary_part(b, 0, 5)
        def e(b), do: :erlang.binary_part(b, {0, 5})
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      pairs = for s <- sites, s.mutator == :call_removal, do: {s.original_code, s.mutated_code}
      assert {"binary_slice(b, 0, 5)", "b"} in pairs
      assert {"binary_slice(0..4)", "Elixir.Function.identity()"} in pairs
      assert {"binary_part(b, 0, 5)", "b"} in pairs
      assert {":erlang.binary_part(b, {0, 5})", "b"} in pairs
      assert_compiles(meta)
    end

    test "binary_part/3 removal reaches a guard via lifting and compiles" do
      source = """
      defmodule R do
        def f(b) when binary_part(b, 0, 1) == "a", do: :yes
        def f(_b), do: :no
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      assert {"binary_part(b, 0, 1)", "b"} in for(
               s <- sites,
               s.mutator == :call_removal,
               do: {s.original_code, s.mutated_code}
             )

      assert_compiles(meta)
    end

    test "the lazy Stream transparent transforms are removable and compile" do
      source = """
      defmodule R do
        def a(xs), do: Stream.uniq(xs)
        def b(xs), do: xs |> Stream.dedup_by(& &1) |> Enum.to_list()
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      pairs = for s <- sites, s.mutator == :call_removal, do: {s.original_code, s.mutated_code}
      assert {"Stream.uniq(xs)", "xs"} in pairs
      assert {"Stream.dedup_by(& &1)", "Elixir.Function.identity()"} in pairs
      assert_compiles(meta)
    end

    test "List.flatten/1 is removed directly and as a pipe stage, and compiles" do
      source = """
      defmodule R do
        def a(xs), do: List.flatten(xs)
        def b(xs), do: xs |> List.flatten()
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      pairs = for s <- sites, s.mutator == :call_removal, do: {s.original_code, s.mutated_code}
      assert {"List.flatten(xs)", "xs"} in pairs
      assert {"List.flatten()", "Elixir.Function.identity()"} in pairs
      assert_compiles(meta)
    end
  end

  describe "DefaultDrop (drop a trailing default/fallback argument)" do
    test "drops a non-nil default (piped and not), skips a nil default, and compiles" do
      source = """
      defmodule D do
        def a(m, k), do: Map.get(m, k, :default)
        def b(m, k), do: m |> Map.get(k, :default)
        def c(m, k), do: Map.get(m, k, nil)
        def d(m, k, f), do: Keyword.get_lazy(m, k, f)
        def e(xs, i), do: List.pop_at(xs, i, :empty)
        def f(xs, i), do: xs |> List.pop_at(i, :empty)
        def g(xs, i), do: List.pop_at(xs, i, nil)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.DefaultDrop]
        )

      pairs = for s <- sites, s.mutator == :default_drop, do: {s.original_code, s.mutated_code}
      assert {"Map.get(m, k, :default)", "Map.get(m, k)"} in pairs
      assert {"Map.get(k, :default)", "Map.get(k)"} in pairs
      assert {"Keyword.get_lazy(m, k, f)", "Keyword.get(m, k)"} in pairs
      assert {"List.pop_at(xs, i, :empty)", "List.pop_at(xs, i)"} in pairs
      assert {"List.pop_at(i, :empty)", "List.pop_at(i)"} in pairs
      # The nil-default call (def c) is equivalent — no mutant.
      refute Enum.any?(pairs, fn {orig, _} -> orig =~ "nil" end)
      assert_compiles(meta)
    end

    test "drops refinement defaults (precision/base/separator/fill/trim) and compiles" do
      source = """
      defmodule R do
        def a(x), do: Float.round(x, 2)
        def b(n), do: Integer.to_string(n, 16)
        def c(xs), do: Enum.join(xs, ", ")
        def d(s, n), do: String.pad_leading(s, n, "*")
        def e(s), do: String.trim(s, "x")
        def f(x), do: Float.round(x, 0)
        def g(xs), do: Enum.join(xs, "")
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.DefaultDrop]
        )

      pairs = for s <- sites, s.mutator == :default_drop, do: {s.original_code, s.mutated_code}
      assert {"Float.round(x, 2)", "Float.round(x)"} in pairs
      assert {"Integer.to_string(n, 16)", "Integer.to_string(n)"} in pairs
      assert {"Enum.join(xs, \", \")", "Enum.join(xs)"} in pairs
      assert {"String.pad_leading(s, n, \"*\")", "String.pad_leading(s, n)"} in pairs
      assert {"String.trim(s, \"x\")", "String.trim(s)"} in pairs
      # The implicit-default precision (0) and separator ("") are equivalent — no mutant.
      refute Enum.any?(pairs, fn {orig, _} ->
               orig =~ "round(x, 0)" or orig =~ ~s|join(xs, "")|
             end)

      assert_compiles(meta)
    end
  end

  describe "MapKeyword (put/put_new overwrite-semantics swaps)" do
    test "swaps put/put_new in place, records the bare swap, and compiles — including in a pipe" do
      source = """
      defmodule M do
        def a(m, k, v), do: Map.put(m, k, v)
        def b(kw, k, v), do: kw |> Keyword.put_new(k, v)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.MapKeyword]
        )

      mutated = for s <- sites, s.mutator == :map_keyword, do: s.mutated_code
      assert "Map.put_new(m, k, v)" in mutated
      # Arity-blind, so it is correct as a pipe stage with no special handling.
      assert "Keyword.put(k, v)" in mutated
      assert_compiles(meta)
    end
  end

  describe "KeywordDelete (delete ↔ delete_first breadth swap)" do
    test "swaps delete ↔ delete_first at /2 (piped and not), skips delete/3, and compiles" do
      source = """
      defmodule K do
        def a(kw, k), do: Keyword.delete(kw, k)
        def b(kw, k), do: kw |> Keyword.delete_first(k)
        def c(kw, k, v), do: Keyword.delete(kw, k, v)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.KeywordDelete]
        )

      pairs = for s <- sites, s.mutator == :keyword_delete, do: {s.original_code, s.mutated_code}
      assert {"Keyword.delete(kw, k)", "Keyword.delete_first(kw, k)"} in pairs
      assert {"Keyword.delete_first(k)", "Keyword.delete(k)"} in pairs
      # The deprecated delete/3 has no delete_first/3 twin — left alone.
      refute Enum.any?(pairs, fn {orig, _} -> orig =~ "delete(kw, k, v)" end)
      assert_compiles(meta)
    end
  end

  describe "MapSet (union/intersection complementary swaps)" do
    test "swaps union ↔ intersection in place, records the swap, and compiles — including in a pipe" do
      source = """
      defmodule M do
        def a(x, y), do: MapSet.union(x, y)
        def b(x, y), do: x |> MapSet.intersection(y)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.MapSet])

      pairs = for s <- sites, s.mutator == :map_set, do: {s.original_code, s.mutated_code}
      assert {"MapSet.union(x, y)", "MapSet.intersection(x, y)"} in pairs
      # Arity-blind, so it is correct as a pipe stage with no special handling.
      assert {"MapSet.intersection(y)", "MapSet.union(y)"} in pairs
      assert_compiles(meta)
    end

    test "an aliased MapSet call mutates, keeping the alias" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias MapSet, as: MS
            def a(x, y), do: MS.union(x, y)
          end
          """,
          mutators: [Mutare.Mutators.MapSet]
        )

      pairs = for s <- sites, s.mutator == :map_set, do: {s.original_code, s.mutated_code}
      assert {"MS.union(x, y)", "MS.intersection(x, y)"} in pairs
      assert_compiles(meta)
    end

    test "a shadowing alias resolves to the local module and is left alone" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule M do
            alias MyApp.MapSet
            def a(x, y), do: MapSet.union(x, y)
          end
          """,
          mutators: [Mutare.Mutators.MapSet]
        )

      assert [] == Enum.filter(sites, &(&1.mutator == :map_set))
    end
  end

  describe "PeriodBoundary (beginning_of ↔ end_of direction swaps)" do
    test "swaps each boundary for its opposite end (including the arity-2 week form), and compiles" do
      source = """
      defmodule P do
        def a(d), do: Date.beginning_of_month(d)
        def b(d), do: Date.end_of_week(d, :sunday)
        def c(n), do: NaiveDateTime.beginning_of_day(n)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PeriodBoundary]
        )

      pairs = for s <- sites, s.mutator == :period_boundary, do: {s.original_code, s.mutated_code}
      assert {"Date.beginning_of_month(d)", "Date.end_of_month(d)"} in pairs
      assert {"Date.end_of_week(d, :sunday)", "Date.beginning_of_week(d, :sunday)"} in pairs

      assert {"NaiveDateTime.beginning_of_day(n)", "NaiveDateTime.end_of_day(n)"} in pairs

      assert_compiles(meta)
    end

    test "an aliased call mutates, keeping the alias" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule P do
            alias Date, as: D
            def a(d), do: D.beginning_of_month(d)
          end
          """,
          mutators: [Mutare.Mutators.PeriodBoundary]
        )

      pairs = for s <- sites, s.mutator == :period_boundary, do: {s.original_code, s.mutated_code}
      assert {"D.beginning_of_month(d)", "D.end_of_month(d)"} in pairs
      assert_compiles(meta)
    end
  end

  # Transform with only CollectionArity, assert the metamutant compiles, and return
  # the `{original_code, mutated_code}` pairs of its sites (for the pipe-aware tests).
  defp arity_sites(source) do
    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source,
        mutators: [Mutare.Mutators.CollectionArity]
      )

    assert_compiles(meta)
    for s <- sites, s.mutator == :collection_arity, do: {s.original_code, s.mutated_code}
  end

  # Transform with only ModeSwap, assert the metamutant compiles, and return the
  # `{original_code, mutated_code}` pairs of its sites.
  defp mode_sites(source) do
    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.ModeSwap])

    assert_compiles(meta)
    for s <- sites, s.mutator == :mode_swap, do: {s.original_code, s.mutated_code}
  end

  # Transform with only Numeric, assert the metamutant compiles, and return the
  # `{original_code, mutated_code}` pairs of its sites.
  defp numeric_sites(source) do
    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.Numeric])

    assert_compiles(meta)
    for s <- sites, s.mutator == :numeric, do: {s.original_code, s.mutated_code}
  end

  defp assert_compiles(meta) do
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  # `message` is either a single substring or a list of substrings that must all
  # be present. A list lets callers match on tokens common to multiple Elixir
  # error-message phrasings (e.g. the import-conflict wording changed in 1.20).
  defp assert_compile_error(meta, message, file) do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise CompileError, fn -> Code.compile_string(meta, file) end
      end)

    for m <- List.wrap(message), do: assert(stderr =~ m)
    stderr
  end
end
