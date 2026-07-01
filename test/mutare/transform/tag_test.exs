defmodule Mutare.Transform.TagTest do
  @moduledoc """
  Focused coverage for `Mutare.Transform.Tag` — the shared *replace-by-tag*
  discovery the lifted-clause (`FunctionPlan`) and `case`/`receive`/`fn`
  (`Analyze`) paths use. These pin the behaviours mutation testing found
  unguarded in the tag walks specifically:

    * the guard-only **redundancy suppression** for `not` over an equality
      operator (and the non-suppression of ordering operators),
    * **descent into collections** in a guard (a literal inside a tuple / list
      still mutates, and is not collapsed by offering the container instead),
    * faithful **reconstruction** of a bitstring segment, a keyword/tuple pair,
      and an n-ary node in the *tagged copy* — proven by rendering the mutant
      clause that materialises from it, not just by `assert_compiles`,
    * **keyword-label keys** staying unmutated in a pattern (the data-key
      shorthand is a label, not a value), while an arrow key is offered,
    * **non-scalar map keys** descending (so their nested literals mutate), and
    * **tag uniqueness** across an `in`-RHS collection plus its `in` node, so a
      sentinel mutant rewrites only the collection, not the whole guard, and
    * **guard-RHS legality** when a custom mutator replaces a list with a map.

  Everything goes through `Mutare.transform_string` (the project convention): a
  corruption in the tag walk shows up in the resulting `sites` / rendered `meta`,
  which is exactly what a per-mutant dogfood run observes.

  ## Equivalent mutants (`# mutare:ignore`d, or left as documented survivors)

  Mutation testing of `tag.ex` leaves a handful of *equivalent mutants* — no test
  can distinguish them because they cannot change observable behaviour. `tag.ex`
  records the verdict at each site: where the equivalent family is the *only* mutant
  kind on its line, a `# mutare:ignore[family]` excludes it; where a family-level
  ignore would *also* hide a genuinely-killed sibling (the tag-counter `1 → 0`
  collision, `conditional → false`, `return_value → nil`), the equivalent is left as
  a documented survivor with a `# NOTE` instead, exactly as `Mutare.Transform.Imports`
  does. The reasoning, per case:

    * **Tag-counter arithmetic** `next + 1` → `next + 2` / `next - 1` (every
      `offer_*` / `tag_*` site that hands out a tag). A tag is an arbitrary
      internal identity used only to find a node again (`replace_tag/3`); all that
      matters is *uniqueness* within the clause group, which `+2` and `-1` preserve
      just as well as `+1` (each is strictly monotonic). Only `+0` collides two
      nodes onto one tag — that *is* a real bug, and the `+0` variant at every such
      site is killed below ("tag uniqueness …", plus the two-element / two-key
      reconstruction tests).
    * **Defensive scalar-type guards** `is_integer(v) or is_float(v) or
      is_binary(v) or is_atom(v)` → `true`, at the two *runtime-body* positions
      Conditional reaches — `literal_node?`'s body and `map_key_values`'s `for`
      filter. These discriminate a *scalar* literal block from a compound one. No
      built-in mutator ever produces a `{:__block__, _, [compound]}` replacement for
      a scalar-literal node, so the guard always holds for the inputs these functions
      receive; its purpose is to fence out a *custom* mutator emitting a
      pattern-illegal replacement, which the built-in suite can't exercise. (The same
      chain in the `tag_pattern_targets`/`tag_pattern_key` *clause heads* is a `when`
      guard, where Conditional can't fire; its `or → and` logical mutant narrows the
      clause and *is* genuinely killed.)
    * **`literal_node?({:-, _, [operand]})` → `:mutare`** — only differs when the
      operand is a non-literal (a built-in never yields `-(<non-literal>)`); the
      negative-literal path itself is covered by `Mutare.NegativeFloatTest`.
    * **`expand_targets`'s `Enum.reverse()` → `Enum.sort()`** (line 70) — the
      targets accumulate in strictly *descending* tag order (a monotonic counter,
      each new target prepended), so reversing them and sorting the `{tag, …}`
      tuples by their unique integer tag both yield the same ascending source
      order. Behaviourally identical.
    * **`replace_tag`'s `when is_list(meta)`** (line 89) → dropped — every node in
      an Elixir AST is `{form, meta, args}` with a *keyword-list* `meta`, so the
      guard never excludes a node `Macro.prewalk` actually visits; it only fences
      out a malformed 3-tuple that can't occur in the trees this walks.
    * **`tag_in_rhs/3`'s `when is_list(args)` guard and its `other` clause**,
      **`tag_pattern_targets/3`'s `%{}` `when is_list(pairs)` guard**, and
      **`tag_map_pair/4`'s `other` clause** — defensive arms that are
      unreachable for valid input: Sourceror wraps every collection literal in a
      `{:__block__, _, [_]}` node (a 3-tuple with list args), a `%{}` node's args
      are always a list, a variable can't be a guard `in`-RHS, and a map pattern's
      entries are always `{key, value}` pairs.
  """
  use ExUnit.Case, async: true

  alias Mutare.Mutators

  defmodule ListToMapMutator do
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :list_to_map

    @impl Mutare.Mutator
    def mutate({:__block__, _meta, [elements]}) when is_list(elements) and elements != [],
      do: [{:%{}, [], []}]

    def mutate(_node), do: :skip
  end

  # One literal in any position the tag walks reach; lets the asserted sites be
  # exactly the literal sites, not perturbed by other families.
  @literal [Mutators.Literal]
  @atom [Mutators.AtomLiteral]

  defp transform(body, mutators) do
    source = "defmodule M do\n  #{String.trim_trailing(body)}\nend\n"
    {meta, sites, _next} = Mutare.transform_string(source, mutators: mutators)
    {meta, sites}
  end

  defp triples(sites), do: for(s <- sites, do: {s.mutator, s.original_code, s.mutated_code})
  defp originals(sites), do: Enum.map(sites, & &1.original_code)

  defp first_id(sites, original_code) do
    sites
    |> Enum.filter(&(&1.original_code == original_code))
    |> Enum.map(& &1.id)
    |> Enum.min()
  end

  describe "guard redundancy suppression: `not` over an equality operator (line 121)" do
    # `not (a != b)` ≡ `a == b` ≡ Logical's strip; Conditional on the inner ≡ the
    # outer's true/false. So the inner equality operator is NOT re-offered to
    # Relational in a guard — only the outer `not` is mutated.
    for op <- [:!=, :===, :!==] do
      test "the inner `#{op}` is not re-offered under a guard `not`" do
        {_meta, sites} =
          transform(
            """
            def f(a, b) when not (a #{unquote(op)} b), do: :ok
            def f(_, _), do: :no
            """,
            [Mutators.Relational, Mutators.Logical, Mutators.Conditional]
          )

        guardish = Enum.filter(sites, &(&1.mutator in [:relational, :logical, :conditional]))

        # The outer `not` strips (Logical) and is forced true/false (Conditional);
        # the inner equality op contributes NOTHING (no Relational re-negation).
        assert {:logical, "not (a #{unquote(op)} b)", "a #{unquote(op)} b"} in triples(guardish)
        refute Enum.any?(guardish, &(&1.mutator == :relational))
      end
    end

    # Ordering operators are deliberately *excluded* from the suppression: their
    # boundary/reversal swaps survive negation as genuinely new mutants. So the
    # `not (a > b)` clause must NOT swallow the inner `>`.
    test "an ordering operator under a guard `not` IS still re-offered" do
      {_meta, sites} =
        transform(
          """
          def f(a, b) when not (a > b), do: :ok
          def f(_, _), do: :no
          """,
          [Mutators.Relational, Mutators.Logical, Mutators.Conditional]
        )

      # The inner `>` keeps its Relational swaps…
      assert {:relational, "a > b", "a >= b"} in triples(sites)
      assert {:relational, "a > b", "a < b"} in triples(sites)
      # …and the outer `not` is still offered too.
      assert {:logical, "not (a > b)", "a > b"} in triples(sites)
    end
  end

  describe "guard redundancy suppression: short-circuit connectives" do
    test "keeps the whole-node constant when the left side has no subsuming boolean-op mutant" do
      {_meta, sites} =
        transform(
          """
          def f(x) when is_integer(x) and x > 0, do: :ok
          def f(_), do: :no
          """,
          [Mutators.Conditional, Mutators.Logical]
        )

      assert {:conditional, "is_integer(x) and x > 0", "false"} in triples(sites)
    end
  end

  describe "guard descent into collection literals (lines 161, 167)" do
    test "a literal inside a tuple in a guard still mutates (the 2-tuple clause descends)" do
      {meta, sites} =
        transform(
          """
          def f(x) when x == {1, 2}, do: :ok
          def f(_), do: :no
          """,
          @literal
        )

      # Both tuple elements are descended and offered; if the 2-tuple clause were
      # dropped, the tuple would be offered as a leaf and its elements skipped.
      assert "1" in originals(sites)
      assert "2" in originals(sites)
      # And the tagged copy reconstructs the tuple faithfully, so the `1` → `2`
      # mutant guard renders `x == {2, 2}` — not a collapsed `x == {}`.
      assert meta =~ "{2, 2}"
      # The two elements carry *distinct* tags, so the `2` → `3` mutant changes only
      # the second (`{1, 3}`); a tag collision would corrupt both into `{3, 3}`.
      assert meta =~ "{1, 3}"
    end

    test "a literal inside a list in a guard still mutates (the list clause descends)" do
      {_meta, sites} =
        transform(
          """
          def f(x) when x in [1, 2], do: :ok
          def f(_), do: :no
          """,
          @literal
        )

      assert "1" in originals(sites)
      assert "2" in originals(sites)
    end

    test "a guard tuple is descended left-to-right, so ids land in source order" do
      {_meta, sites} =
        transform(
          """
          def f(x) when x == {1, 2}, do: :ok
          def f(_), do: :no
          """,
          @literal
        )

      # The left element (`1`) is tagged before the right (`2`); swapping the
      # descent order would give `2` the lower ids.
      assert first_id(sites, "1") < first_id(sites, "2")
    end
  end

  describe "guard membership RHS legality" do
    test "drops a custom list-to-map mutation in a guard but retains it in a body" do
      {guard_meta, guard_sites} =
        transform(
          """
          def f(x) when x in [1, 2], do: :ok
          def f(_), do: :no
          """,
          [ListToMapMutator]
        )

      refute Enum.any?(guard_sites, &(&1.mutator == :list_to_map))
      assert [_ | _] = Mutare.Test.Compile.string(guard_meta)

      {body_meta, body_sites} =
        transform("def f(x), do: x in [1, 2]", [ListToMapMutator])

      assert {:list_to_map, "[1, 2]", "%{}"} in triples(body_sites)
      assert [_ | _] = Mutare.Test.Compile.string(body_meta)
    end
  end

  describe "faithful tagged-copy reconstruction, proven by the materialised mutant clause" do
    test "a bitstring segment in a guard keeps its `::` spec (line 209)" do
      {meta, sites} =
        transform(
          """
          def f(x) when <<x::integer-size(8)>> == <<0>>, do: :ok
          def f(_), do: :no
          """,
          @literal
        )

      # `size(8)`'s `8` is the one runtime spec sub-position, so it mutates…
      assert "8" in originals(sites)
      # …and the mutant clause renders the full segment, not a corrupted stub.
      assert meta =~ "integer-size(9)"
      assert meta =~ "integer-size(7)"
    end

    test "a bitstring segment in a pattern head keeps its `::` spec (line 288)" do
      {meta, _sites} =
        transform(
          """
          def f(<<5::integer>>), do: :ok
          def f(_), do: :no
          """,
          @literal
        )

      # The head-literal `5` mutant must render as a legal `<<6::integer>>` head —
      # corrupting the segment (`:mutare(...)`, `<<>>` with no spec, `{}`) drops
      # the `6::integer` form entirely.
      assert meta =~ "6::integer"
    end

    test "a 2-tuple pattern head keeps both elements (line 320)" do
      {meta, _sites} =
        transform(
          """
          def f({1, 2}), do: :ok
          def f(_), do: :no
          """,
          @literal
        )

      # The `1` → `2` mutant head must render `{2, 2}`, not `{}`.
      assert meta =~ "{2, 2}"
      # Distinct tags per element: the `2` → `3` mutant changes only the second
      # (`{1, 3}`); a non-advancing tag counter would collide them into `{3, 3}`.
      assert meta =~ "{1, 3}"
    end

    test "a list pattern head keeps its elements (line 328)" do
      {meta, _sites} =
        transform(
          """
          def f([1, 2]), do: :ok
          def f(_), do: :no
          """,
          @literal
        )

      assert meta =~ "[2, 2]"
    end

    test "two negative-literal patterns get distinct tags and value-mutate independently (lines 267, 279)" do
      # Two negatives in one head exercise the dedicated negative-literal clause
      # twice, threading its `{next, targets}` acc between them:
      #   * a swap of the acc (`{targets, next}`) computes `[] + 1` and raises here,
      #   * a non-advancing tag counter (`next + 0`) collides the two literals onto
      #     one tag, so mutating the first would rewrite the second too.
      {meta, sites} =
        transform(
          """
          def f(-0.5, -1.5), do: :ok
          def f(_, _), do: :no
          """,
          [Mutators.FloatLiteral]
        )

      # Each negative is mutated *by value* (the whole `-n` node), independently.
      assert {:float, "-0.5", "0.5"} in triples(sites)
      assert {:float, "-1.5", "-2.5"} in triples(sites)

      # The first arg's mutant leaves the second untouched, and vice-versa — distinct
      # tags. A collision would render `(…, 0.5, 0.5)` / `(…, -0.5, -0.5)` instead.
      assert meta =~ "mutare_active, 0.5, -1.5)"
      assert meta =~ "mutare_active, -0.5, -2.5)"
      # …and every replacement is a clean self-contained literal, never a nested `-(-x)`.
      refute meta =~ "-(-0.5)"
    end
  end

  describe "keyword-label keys are labels, not values (lines 314, 389)" do
    test "a keyword-list pattern key is not mutated; its value is" do
      {meta, sites} =
        transform(
          """
          def f([a: :b]), do: :ok
          def f(_), do: :no
          """,
          @atom
        )

      # The value `:b` is a head literal and mutates; the label `a:` is structural
      # and must NOT be offered (which would rewrite the key to `[mutare: :b]`). The
      # keyword key renders `a:`, so check that exact written form is never a site.
      assert {:atom, ":b", ":mutare"} in triples(sites)
      refute "a:" in originals(sites)
      # The pair is also reconstructed faithfully in the tagged copy, so the value
      # mutant renders `[a: :mutare]` — not a collapsed `[{}]` that drops the key.
      assert meta =~ "a: :mutare"
    end

    test "a map-shorthand pattern key is not mutated; its value is" do
      {_meta, sites} =
        transform(
          """
          def f(%{a: :b}), do: :ok
          def f(_), do: :no
          """,
          @atom
        )

      assert {:atom, ":b", ":mutare"} in triples(sites)
      refute "a:" in originals(sites)
    end

    test "an *arrow* map key IS a value position and is offered (contrast)" do
      {_meta, sites} =
        transform(
          """
          def f(%{:a => :b}), do: :ok
          def f(_), do: :no
          """,
          @atom
        )

      # `%{:a => :b}` writes the key in value position, so both key and value
      # mutate — the keyword-label skip is specific to the `a:` shorthand.
      assert ":a" in originals(sites)
      assert ":b" in originals(sites)
    end
  end

  describe "non-scalar map keys descend (line 416)" do
    test "a tuple map key's nested literals still mutate" do
      {_meta, sites} =
        transform(
          """
          def f(%{{1, 2} => v}), do: v
          def f(_), do: :no
          """,
          @literal
        )

      # The key `{1, 2}` is not a scalar literal, so it descends to its elements
      # (the fallback clause); dropping that clause raises mid-transform.
      assert "1" in originals(sites)
      assert "2" in originals(sites)
    end
  end

  describe "tag uniqueness across mutatable nodes (lines 198, 238, 253, 412)" do
    test "a sigil sentinel mutant rewrites only the collection, not the whole guard (line 198)" do
      {meta, sites} =
        transform(
          """
          def f(x) when x in ~w(a b), do: :ok
          def f(_), do: :no
          """,
          [Mutators.WordListLiteral, Mutators.Relational]
        )

      # The collection and the `in` node both get mutants, so they must carry
      # distinct tags. If they collided, materialising the `~w(mutare)` sentinel
      # would `replace_tag` the *outer* `in` node and render `when ~w(mutare)`
      # (a non-membership guard), losing the `x in ` prefix.
      assert {:word_list, "~w(a b)", "~w(mutare)"} in triples(sites)
      assert {:relational, "x in ~w(a b)", "x not in ~w(a b)"} in triples(sites)
      assert meta =~ "x in ~w(mutare)"
    end

    test "two scalar map keys get distinct tags and mutate independently (line 412)" do
      {meta, sites} =
        transform(
          """
          def f(%{1 => :a, 2 => :b}), do: :ok
          def f(_), do: :no
          """,
          @literal
        )

      # Both value-position keys are offered (collision-filtered against each other,
      # so `1` never becomes the sibling `2`)…
      assert {:literal, "1", "0"} in triples(sites)
      assert {:literal, "2", "3"} in triples(sites)
      # …and they carry distinct tags: the `2` → `3` mutant changes only the second
      # key (`%{1 => :a, 3 => :b}`). A collision would rewrite both to the same key
      # (`%{3 => :a, 3 => :b}`) — a duplicate-key clause that also fails to compile.
      assert meta =~ "1 => :a, 3 => :b"
    end
  end
end
