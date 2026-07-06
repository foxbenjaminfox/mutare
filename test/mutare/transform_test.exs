defmodule Mutare.TransformTest do
  use ExUnit.Case, async: true

  alias Mutare.Site

  # These tests probe *context routing* (which positions are mutated vs pruned), not the
  # default mutator set. Pin them to the two operator-swap families so adding higher-volume
  # defaults can't perturb the exact site counts they assert. Positive coverage of the
  # defaults lives in mutators_test.exs and its siblings.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  # The per-site active-id read is hoisted, so a tupled-case subject reads the bound
  # `mutare_active` variable, not the inline persistent_term read. The variable name
  # (unlike the persistent_term key) is independent of `Selector.suite_key/0`, so this
  # holds under dogfooding.
  defp selector_tuple(subject), do: "case {mutare_active, #{subject}}"

  @sample """
  defmodule Sample do
    def classify(total, threshold) do
      if total >= threshold do
        :ok
      else
        :under
      end
    end

    def add(a, b), do: a + b
  end
  """

  test "discovers every arithmetic and relational site, ids assigned sequentially" do
    {_meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@sample, file: "sample.ex", mutators: @probe)

    # >= -> {>, <=}  (2),  + -> -  (1)
    assert length(sites) == 3
    assert Enum.map(sites, & &1.id) == [1, 2, 3]
    assert Enum.all?(sites, &(&1.file == "sample.ex"))
  end

  test "records operators, lines and a readable description" do
    {_meta, [s1, s2, s3], _next_id} =
      Mutare.Transform.transform_string_with_sites(@sample, mutators: @probe)

    assert %Site{mutator: :relational, original_form: :>=, mutated_form: :>, line: 3} = s1
    assert %Site{mutator: :relational, original_form: :>=, mutated_form: :<=, line: 3} = s2
    assert %Site{mutator: :arithmetic, original_form: :+, mutated_form: :-, line: 10} = s3

    assert Site.describe(s1) == "relational  total >= threshold → total > threshold"
    assert Site.describe(s3) == "arithmetic  a + b → a - b"
  end

  test "metamutant bakes in the persistent_term selector with the shared key" do
    {meta, _sites, _next_id} = Mutare.Transform.transform_string_with_sites(@sample)
    assert meta =~ ":persistent_term.get(#{inspect(Mutare.Selector.key())}, 0)"
  end

  test "metamutant is valid, compilable Elixir" do
    {meta, _sites, _next_id} = Mutare.Transform.transform_string_with_sites(@sample)
    assert {:ok, _ast} = Code.string_to_quoted(meta)
  end

  test ":start_id offsets the first id" do
    {_meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@sample, start_id: 100, mutators: @probe)

    assert Enum.map(sites, & &1.id) == [100, 101, 102]
  end

  test ":mutators selects which families run" do
    {_meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@sample,
        mutators: [Mutare.Mutators.Arithmetic]
      )

    assert [%Site{mutator: :arithmetic, original_form: :+}] = sites
  end

  describe "count_string/2 (the schema's render-free count pass)" do
    test "equals the full transform's mutant count, drift-proof by construction" do
      # Cross-file id stability rests on this: the count pass and the render pass run the
      # same deterministic pipeline, so the count equals `next_id - start_id` exactly.
      # Cover both a pinned subset and the full default set (key omitted → default).
      for opts <- [[file: "sample.ex", mutators: @probe], [file: "sample.ex"]] do
        {_meta, sites, next_id} = Mutare.Transform.transform_string_with_sites(@sample, opts)

        assert Mutare.Transform.count_string(@sample, opts) == length(sites)
        assert Mutare.Transform.count_string(@sample, opts) == next_id - 1
      end
    end

    test "is independent of :start_id and :skip_ids (a skipped id still advances the counter)" do
      base = Mutare.Transform.count_string(@sample, mutators: @probe)

      assert Mutare.Transform.count_string(@sample, mutators: @probe, start_id: 500) == base

      assert Mutare.Transform.count_string(@sample,
               mutators: @probe,
               skip_ids: MapSet.new([1, 2])
             ) ==
               base
    end

    test "raises the parser exception on an unparseable source" do
      assert_raise SyntaxError, fn ->
        Mutare.Transform.count_string("x = %{a: }\n")
      end
    end
  end

  test "a custom mutator plugs in for both in-place and lifted delivery" do
    source = """
    defmodule X do
      def body(a, b), do: a and b
      def guarded(a, b) when a and b, do: :ok
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Test.BooleanMutator])

    # body `a and b` → in-place; guard `a and b` → lifted. The author wrote one
    # `mutate/1`; placement is decided by position.
    assert %Site{mutator: :boolean, original_form: :and, mutated_form: :or, kind: :in_place} =
             Enum.find(sites, &(&1.kind == :in_place))

    assert %Site{mutator: :boolean, original_form: :and, mutated_form: :or, kind: :lifted} =
             Enum.find(sites, &(&1.kind == :lifted))

    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "nested operator sites both get their own selector" do
    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(
        "defmodule N do\n  def f(a, b), do: a + b == 0\nend\n",
        mutators: @probe
      )

    # + -> - (1) and == -> != (1)
    assert Enum.map(sites, &{&1.mutator, &1.original_form}) ==
             [{:arithmetic, :+}, {:relational, :==}]

    # Two independent selectors are present. The per-site `:persistent_term.get` read is
    # now hoisted to one per function (a `:do`-block prologue), and every selector reads
    # that bound variable — so count the hoisted selector *subjects* (`case mutare_active
    # do`), of which there is one per site. The variable name (unlike the persistent_term
    # key) is independent of `Selector.suite_key/0`, so this holds under dogfooding.
    assert meta |> String.split("case mutare_active do") |> length() == 3
    # The read itself is hoisted to exactly one prologue for the whole function.
    read = ":persistent_term.get(#{inspect(Mutare.Selector.key())}, 0)"
    assert meta |> String.split(read) |> length() == 2
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "guard operators become lifted mutants; body operators stay in-place" do
    source = """
    defmodule G do
      def f(x) when x >= 0 and x < 100, do: x + 1
      def f(_), do: 0
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    # Guards are lifted: >= -> {>, <=} and < -> {<=, >} (operation :replace).
    guards = Enum.filter(sites, &(&1.kind == :lifted and &1.operation == :replace))
    assert Enum.frequencies_by(guards, & &1.original_form) == %{:>= => 2, :< => 2}

    # The body `+` stays in-place.
    assert [%Site{kind: :in_place, mutator: :arithmetic, original_form: :+}] =
             Enum.filter(sites, &(&1.kind == :in_place))

    # A `case` must never appear inside a guard (that would compile-poison).
    refute meta =~ "when (case"
    refute meta =~ "when case"

    # Lifted into one private group that takes the active id as an extra arg, with
    # each guard mutant a single clause gated `when mutare_active === <id> …` — not
    # a full per-mutant copy of the clause group.
    assert meta =~ ~r/defp __mutare_f_1_g\d+\(mutare_active,/
    assert meta =~ ~r/when mutare_active === \d+ and/
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "the `/` in a &fun/arity capture is not mutated (it is arity, not division)" do
    source = """
    defmodule C do
      def run, do: Enum.map([1, 2], &double/1)
      def double(x), do: x * 2
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    # Only the body `x * 2` is a site; the capture's `/1` is left alone.
    assert [%Site{mutator: :arithmetic, original_form: :*}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "division in a capture body (`& &1 / 2`) is still mutated" do
    {_meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(
        "defmodule C do\n  def half, do: &(&1 / 2)\nend\n",
        mutators: @probe
      )

    assert [%Site{mutator: :arithmetic, original_form: :/, mutated_form: :*}] = sites
  end

  test "module-attribute (compile-time) expressions are not mutated" do
    source = """
    defmodule A do
      @threshold 1 + 2
      def limit, do: @threshold
      def bump(n), do: n + @threshold
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    # The `1 + 2` in the attribute definition is compile-time and inert, so it
    # produces no mutant. Only the runtime body `n + @threshold` is mutated.
    assert [%Site{mutator: :arithmetic, original_form: :+, line: 4}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "a bitstring value and its size(...) arg mutate; the spec side is excluded" do
    source = "defmodule B do\n  def f(n), do: <<(n + 1)::size(n * 8)>>\nend\n"

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    # The value `n + 1` and the runtime `size(n * 8)` argument both mutate; a
    # `case` is legal in both positions.
    assert Enum.frequencies_by(sites, &{&1.mutator, &1.original_form}) ==
             %{{:arithmetic, :+} => 1, {:arithmetic, :*} => 1}

    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "bitstring spec separators are not mutated (a swapped `-` is an illegal specifier)" do
    source = "defmodule B do\n  def f(x), do: <<x::integer-big-size(16)>>\nend\n"

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    assert sites == []
    refute meta =~ "integer + big"
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "bitstring unit(...) args are not mutated" do
    source = "defmodule B do\n  def f(x), do: <<x::size(1)-unit(8)>>\nend\n"

    {_meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    assert sites == []
  end

  test "a bitstring in a pattern is excluded; the body still mutates" do
    source = "defmodule B do\n  def f(<<x::size(8)>>), do: x + 1\nend\n"

    {_meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    assert [%Site{mutator: :arithmetic, original_form: :+}] = sites
  end

  test "a bitstring spec separator in a guard is not mutated (the lifted path is spec-aware)" do
    # A multi-specifier bitstring construction is a *legal* guard. The guard is
    # lifted (the `==` makes the clause lift), so its segments travel the tag
    # walker, not the in-place analyzer. A blind walk would offer the `-`
    # separator to Arithmetic and lift `<<x::(integer + size(8))>>`, an "unknown
    # bitstring specifier" that poisons the whole build.
    source = """
    defmodule B do
      def f(x) when <<x::integer-size(8)>> == <<0>>, do: :ok
      def f(_), do: :no
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.Arithmetic])

    # The function lifts (it is multi-clause), so the guard travels the tag walker.
    # The `-` separator yields no Arithmetic mutant; the metamutant compiles, not
    # just parses.
    refute Enum.any?(sites, &(&1.mutator == :arithmetic))
    refute meta =~ "integer + size"
    assert_compiles(meta)
  end

  test "a size(...) arg inside a guard bitstring still mutates (the runtime sub-position)" do
    source = """
    defmodule B do
      def f(x) when <<x::integer-size(8)>> == <<0>>, do: :ok
      def f(_), do: :no
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.Literal])

    # `size(8)`'s `8` is the one spec sub-position the lifted walker descends.
    assert Enum.any?(sites, &(&1.original_code == "8"))
    assert_compiles(meta)
  end

  test "a bitstring literal collapses to <<>>; a sigil's content is not offered" do
    source = """
    defmodule B do
      def f, do: <<1, 2, 3>>
      def g, do: ~r/foo/
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source,
        mutators: [Mutare.Mutators.BitstringLiteral, Mutare.Mutators.RegexLiteral]
      )

    # The `<<1, 2, 3>>` literal gets one :bitstring site; `~r/foo/`'s inner `<<>>`
    # content is *not* offered to BitstringLiteral (only RegexLiteral's two).
    assert Enum.frequencies_by(sites, & &1.mutator) == %{bitstring: 1, regex: 2}
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "an interpolated expression inside a sigil still mutates; the content <<>> does not collapse" do
    source = "defmodule S do\n  def f(b), do: ~r/a\#{b + 1}c/\nend\n"

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source,
        mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.BitstringLiteral]
      )

    # `b + 1` inside the interpolation mutates; the sigil's content `<<>>` is never
    # offered to BitstringLiteral (no :bitstring site).
    assert [%Site{mutator: :arithmetic, original_form: :+}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "an interpolated atom mutates as a whole; its content <<>> does not collapse" do
    source = "defmodule A do\n  def f(b), do: :\"a\#{b + 1}c\"\nend\n"

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source,
        mutators: [
          Mutare.Mutators.Arithmetic,
          Mutare.Mutators.AtomLiteral,
          Mutare.Mutators.BitstringLiteral
        ]
      )

    # The whole `:"a#{b + 1}c"` swaps to the sentinel (AtomLiteral); `b + 1` inside the
    # interpolation still mutates; the content `<<>>` is never offered to BitstringLiteral.
    assert Enum.frequencies_by(sites, & &1.mutator) == %{atom: 1, arithmetic: 1}
    assert %Site{mutated_code: ":mutare"} = Enum.find(sites, &(&1.mutator == :atom))
    assert_compiles(meta)
  end

  test "interpolated charlists (sigil and legacy) mutate as a whole; interiors still mutate" do
    source = "defmodule C do\n  def f(b), do: {~c\"a\#{b + 1}c\", 'd\#{b + 2}e'}\nend\n"

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source,
        mutators: [
          Mutare.Mutators.Arithmetic,
          Mutare.Mutators.CharlistLiteral,
          Mutare.Mutators.BitstringLiteral,
          Mutare.Mutators.List
        ]
      )

    # Each form yields the empty + sentinel pair; the interiors mutate; neither the
    # legacy segment list nor any content `<<>>` is offered to List / BitstringLiteral.
    # (Parsed via Sourceror so the metamutant's legacy `'…'` doesn't print the
    # single-quote deprecation warning into the test output.)
    assert Enum.frequencies_by(sites, & &1.mutator) == %{charlist: 4, arithmetic: 2}
    assert {:ok, _} = Sourceror.parse_string(meta)
  end

  test "a plain legacy charlist splits ownership: List empties it, CharlistLiteral sentinels it" do
    source = "defmodule L do\n  def f, do: 'abc'\nend\n"

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source,
        mutators: [Mutare.Mutators.CharlistLiteral, Mutare.Mutators.List]
      )

    assert Enum.map(sites, &{&1.mutator, &1.mutated_code}) == [
             {:charlist, ~S|~c"mutare"|},
             {:list, "[]"}
           ]

    assert {:ok, _} = Sourceror.parse_string(meta)
  end

  test "defmacro/defmacrop bodies are compile-time and not mutated" do
    source = """
    defmodule M do
      defmacro plus(a, b), do: quote(do: unquote(a) + unquote(b))
      defmacrop minus(a, b), do: quote(do: unquote(a) - unquote(b))
      def use(x), do: x * 2
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    # The `+`/`-` inside the macro bodies run at expansion time and never see the
    # runtime selector; only the real body `x * 2` mutates.
    assert [%Site{mutator: :arithmetic, original_form: :*}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "a defmacro with a non-quote arithmetic body is still excluded" do
    source = "defmodule M do\n  defmacro c, do: 1 + 2\nend\n"

    {_meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    assert sites == []
  end

  test "a default-argument value runs at call time and still mutates" do
    source = "defmodule D do\n  def f(x \\\\ 1 + 2), do: x\nend\n"

    {_meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    assert [%Site{mutator: :arithmetic, original_form: :+}] = sites
  end

  test "a quote block is compile-time; runtime code around it still mutates" do
    source = """
    defmodule Q do
      def build(x) do
        _ = x + 1

        quote do
          case unquote(x) do
            "" -> 0
            _ -> 1
          end
        end
      end
    end
    """

    # Default set on purpose: `literal`/`string` *would* mutate the `""` clause
    # head and the `0`/`1` bodies inside the quote — splicing a selector `case`
    # into a quoted *pattern* (illegal where the AST is later compiled, a poison
    # the pre-filter can't see). The whole quote is pruned, so the only sites are
    # from `x + 1` on line 3, outside the quote.
    {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

    assert sites != []
    assert Enum.all?(sites, &(&1.line == 3))
    assert Enum.any?(sites, &(&1.mutator == :arithmetic))
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "import/alias/require directives are compile-time and never mutated" do
    source = """
    defmodule D do
      alias Enum, as: E
      import List, only: [first: 1]
      require Integer

      def total(xs), do: E.sum(xs) + 1
    end
    """

    # Pinned to the *default* set on purpose: the `literal`/`list` families would
    # mutate the `1` arity and the `[first: 1]` keyword list in `import`'s `only:`
    # if the directive weren't pruned — and a selector `case` there makes `only:`
    # a non-literal, which fails to compile and sinks the single build. So the
    # directive lines (2..4) must carry no site; only the runtime body (line 6) does.
    {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

    refute Enum.any?(sites, &(&1.line in 2..4))
    assert Enum.any?(sites, &(&1.line == 6))
    # The `only:` list rides through verbatim — no selector wrapped around it.
    assert meta =~ "only: [first: 1]"
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "a case-clause guard IS mutated (tuple-the-scrutinee), and so is the clause body" do
    source = """
    defmodule K do
      def f(x) do
        case x do
          n when n > 1 -> n + 1
          _ -> 0
        end
      end
    end
    """

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    # A `case` clause's guard now mutates via the tuple-the-scrutinee rewrite (the
    # per-clause analogue of head-guard lifting): the subject is tupled with the active
    # id and each mutant adds a gated clause. The guard `n > 1` (relational) and the
    # body `n + 1` (arithmetic) both mutate, delivered in place — no `case` ever lands
    # in a guard.
    assert Enum.any?(sites, &(&1.original_form == :> and &1.kind == :in_place))
    assert Enum.any?(sites, &(&1.original_form == :+ and &1.kind == :in_place))
    assert meta =~ selector_tuple("x")
    refute meta =~ "when (case"
    refute meta =~ "when case"
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "comprehension filters and bodies mutate; the generator pattern does not" do
    source = "defmodule F do\n  def f(xs), do: for(x <- xs, x > 0, do: x + 1)\nend\n"

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    # Filter `x > 0` (2 relational swaps) and body `x + 1` (1 swap) both mutate;
    # the generator pattern `x` does not.
    assert Enum.frequencies_by(sites, & &1.original_form) == %{:> => 2, :+ => 1}
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  describe "for ... reduce: comprehension do-blocks" do
    # The `do:` body of a `reduce:` comprehension is a *stab-clause* set (`acc -> expr`).
    # Sourceror represents it identically to a list literal — `{:__block__, _, [[…]]}` —
    # so before the fix `Mutare.Mutators.List` collapsed it to `[]`, and the `for` special
    # form rejects that at *compile* time ("the do block must be written using acc -> expr
    # clauses"), poisoning the single build. `Code.string_to_quoted` would not catch it (the
    # metamutant parses fine), so these assertions compile the metamutant, not just parse it.
    @reduce """
    defmodule R do
      def sum(counts, pred) do
        for {status, n} <- counts, pred.(status), reduce: 0, do: (acc -> acc + n)
      end
    end
    """

    test "the List family never collapses the do-block to []" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@reduce, mutators: [Mutare.Mutators.List])

      # The wrapper is a stab-clause block, not a real list literal, so List finds nothing.
      assert sites == []
      refute meta =~ "do: []"
      assert_compiles(meta)
    end

    test "the accumulator body still mutates and the full-set metamutant compiles" do
      {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(@reduce)

      # The body `acc + n` is ordinary runtime, so it still mutates (we suppress only the
      # bogus wrapper collapse, not the legitimate sub-position mutations)...
      assert Enum.any?(sites, &(&1.mutator == :arithmetic and &1.original_form == :+))
      # ...and the whole metamutant compiles under every default family, not just parses.
      assert_compiles(meta)
    end

    test "a multi-clause reduce body (guards + several arrows) compiles" do
      source = """
      defmodule R2 do
        def tally(xs) do
          for x <- xs, reduce: %{} do
            acc when is_integer(x) -> Map.update(acc, :int, 1, &(&1 + 1))
            acc -> Map.update(acc, :other, 1, &(&1 + 1))
          end
        end
      end
      """

      {meta, _sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)
      assert_compiles(meta)
    end
  end

  test "a cond-clause condition is runtime and still mutates" do
    source = """
    defmodule C do
      def f(a) do
        cond do
          a > 1 -> :hi
          true -> :lo
        end
      end
    end
    """

    {_meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: @probe)

    # The `->` left side in a `cond` is a runtime condition, not a pattern.
    assert Enum.frequencies_by(sites, & &1.original_form) == %{:> => 2}
  end

  defp assert_compiles(meta) do
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end
end
