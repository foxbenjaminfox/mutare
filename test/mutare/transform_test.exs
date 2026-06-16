defmodule Mutare.TransformTest.PlusOneMutator do
  @moduledoc """
  A custom mutator that rewrites an integer literal `n` to `n + 1` — an *operator*
  expression. Legal in a body, but illegal in a pattern, so it exercises the
  head-pattern literal filter (only literal-valued replacements survive a head).
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :plus_one

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}) when is_integer(n),
    do: [{:+, [], [{:__block__, [], [n]}, {:__block__, [], [1]}]}]

  def mutate(_node), do: :skip
end

defmodule Mutare.TransformTest do
  use ExUnit.Case, async: true

  alias Mutare.Site

  # These tests probe *context routing* (which positions are mutated vs pruned),
  # not the default mutator set. Pin them to the two operator-swap families so
  # adding higher-volume defaults (literals, logical, …) can't perturb the exact
  # site counts they assert. Positive coverage of the new defaults lives in its
  # own test below and in mutators_test.exs.
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

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
      Mutare.transform_string(@sample, file: "sample.ex", mutators: @probe)

    # >= -> {>, <=}  (2),  + -> -  (1)
    assert length(sites) == 3
    assert Enum.map(sites, & &1.id) == [1, 2, 3]
    assert Enum.all?(sites, &(&1.file == "sample.ex"))
  end

  test "records operators, lines and a readable description" do
    {_meta, [s1, s2, s3], _next_id} = Mutare.transform_string(@sample, mutators: @probe)

    assert %Site{mutator: :relational, original_op: :>=, mutated_op: :>, line: 3} = s1
    assert %Site{mutator: :relational, original_op: :>=, mutated_op: :<=, line: 3} = s2
    assert %Site{mutator: :arithmetic, original_op: :+, mutated_op: :-, line: 10} = s3

    assert Site.describe(s1) == "relational  total >= threshold → total > threshold"
    assert Site.describe(s3) == "arithmetic  a + b → a - b"
  end

  test "metamutant bakes in the persistent_term selector with the shared key" do
    {meta, _sites, _next_id} = Mutare.transform_string(@sample)
    assert meta =~ ":persistent_term.get(#{inspect(Mutare.Selector.key())}, 0)"
  end

  test "metamutant is valid, compilable Elixir" do
    {meta, _sites, _next_id} = Mutare.transform_string(@sample)
    assert {:ok, _ast} = Code.string_to_quoted(meta)
  end

  test ":start_id offsets the first id" do
    {_meta, sites, _next_id} = Mutare.transform_string(@sample, start_id: 100, mutators: @probe)
    assert Enum.map(sites, & &1.id) == [100, 101, 102]
  end

  test ":mutators selects which families run" do
    {_meta, sites, _next_id} =
      Mutare.transform_string(@sample, mutators: [Mutare.Mutators.Arithmetic])

    assert [%Site{mutator: :arithmetic, original_op: :+}] = sites
  end

  test "a custom mutator plugs in for both in-place and lifted delivery" do
    source = """
    defmodule X do
      def body(a, b), do: a and b
      def guarded(a, b) when a and b, do: :ok
    end
    """

    {meta, sites, _next_id} =
      Mutare.transform_string(source, mutators: [Mutare.Test.BooleanMutator])

    # body `a and b` → in-place; guard `a and b` → lifted. The author wrote one
    # `mutate/1`; placement is decided by position.
    assert %Site{mutator: :boolean, original_op: :and, mutated_op: :or, kind: :in_place} =
             Enum.find(sites, &(&1.kind == :in_place))

    assert %Site{mutator: :boolean, original_op: :and, mutated_op: :or, kind: :lifted} =
             Enum.find(sites, &(&1.kind == :lifted))

    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "nested operator sites both get their own selector" do
    {meta, sites, _next_id} =
      Mutare.transform_string("defmodule N do\n  def f(a, b), do: a + b == 0\nend\n",
        mutators: @probe
      )

    # + -> - (1) and == -> != (1)
    assert Enum.map(sites, &{&1.mutator, &1.original_op}) ==
             [{:arithmetic, :+}, {:relational, :==}]

    # two independent selectors are present (count the selector *subject*; the
    # catch-all coverage record also reads `:persistent_term.get(:mutare_track, …)`)
    assert meta |> String.split(":persistent_term.get(:mutare_active") |> length() == 3
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "guard operators become lifted mutants; body operators stay in-place" do
    source = """
    defmodule G do
      def f(x) when x >= 0 and x < 100, do: x + 1
      def f(_), do: 0
    end
    """

    {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    # Guards are lifted: >= -> {>, <=} and < -> {<=, >} (operation :replace).
    guards = Enum.filter(sites, &(&1.kind == :lifted and &1.operation == :replace))
    assert Enum.frequencies_by(guards, & &1.original_op) == %{:>= => 2, :< => 2}

    # The body `+` stays in-place.
    assert [%Site{kind: :in_place, mutator: :arithmetic, original_op: :+}] =
             Enum.filter(sites, &(&1.kind == :in_place))

    # A `case` must never appear inside a guard (that would compile-poison).
    refute meta =~ "when (case"
    refute meta =~ "when case"
    assert meta =~ ~r/__mutare_f_1_g\d+_orig/
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "the `/` in a &fun/arity capture is not mutated (it is arity, not division)" do
    source = """
    defmodule C do
      def run, do: Enum.map([1, 2], &double/1)
      def double(x), do: x * 2
    end
    """

    {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    # Only the body `x * 2` is a site; the capture's `/1` is left alone.
    assert [%Site{mutator: :arithmetic, original_op: :*}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "division in a capture body (`& &1 / 2`) is still mutated" do
    {_meta, sites, _next_id} =
      Mutare.transform_string("defmodule C do\n  def half, do: &(&1 / 2)\nend\n",
        mutators: @probe
      )

    assert [%Site{mutator: :arithmetic, original_op: :/, mutated_op: :*}] = sites
  end

  test "module-attribute (compile-time) expressions are not mutated" do
    source = """
    defmodule A do
      @threshold 1 + 2
      def limit, do: @threshold
      def bump(n), do: n + @threshold
    end
    """

    {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    # The `1 + 2` in the attribute definition is compile-time and inert, so it
    # produces no mutant. Only the runtime body `n + @threshold` is mutated.
    assert [%Site{mutator: :arithmetic, original_op: :+, line: 4}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "a bitstring value and its size(...) arg mutate; the spec side is excluded" do
    source = "defmodule B do\n  def f(n), do: <<(n + 1)::size(n * 8)>>\nend\n"
    {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    # The value `n + 1` and the runtime `size(n * 8)` argument both mutate; a
    # `case` is legal in both positions.
    assert Enum.frequencies_by(sites, &{&1.mutator, &1.original_op}) ==
             %{{:arithmetic, :+} => 1, {:arithmetic, :*} => 1}

    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "bitstring spec separators are not mutated (a swapped `-` is an illegal specifier)" do
    source = "defmodule B do\n  def f(x), do: <<x::integer-big-size(16)>>\nend\n"
    {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    assert sites == []
    refute meta =~ "integer + big"
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "bitstring unit(...) args are not mutated" do
    source = "defmodule B do\n  def f(x), do: <<x::size(1)-unit(8)>>\nend\n"
    {_meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    assert sites == []
  end

  test "a bitstring in a pattern is excluded; the body still mutates" do
    source = "defmodule B do\n  def f(<<x::size(8)>>), do: x + 1\nend\n"
    {_meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    assert [%Site{mutator: :arithmetic, original_op: :+}] = sites
  end

  test "a bitstring literal collapses to <<>>; a sigil's content is not offered" do
    source = """
    defmodule B do
      def f, do: <<1, 2, 3>>
      def g, do: ~r/foo/
    end
    """

    {meta, sites, _next_id} =
      Mutare.transform_string(source,
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
      Mutare.transform_string(source,
        mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.BitstringLiteral]
      )

    # `b + 1` inside the interpolation mutates; the sigil's content `<<>>` is never
    # offered to BitstringLiteral (no :bitstring site).
    assert [%Site{mutator: :arithmetic, original_op: :+}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "defmacro/defmacrop bodies are compile-time and not mutated" do
    source = """
    defmodule M do
      defmacro plus(a, b), do: quote(do: unquote(a) + unquote(b))
      defmacrop minus(a, b), do: quote(do: unquote(a) - unquote(b))
      def use(x), do: x * 2
    end
    """

    {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    # The `+`/`-` inside the macro bodies run at expansion time and never see the
    # runtime selector; only the real body `x * 2` mutates.
    assert [%Site{mutator: :arithmetic, original_op: :*}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "a defmacro with a non-quote arithmetic body is still excluded" do
    source = "defmodule M do\n  defmacro c, do: 1 + 2\nend\n"
    {_meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    assert sites == []
  end

  test "a default-argument value runs at call time and still mutates" do
    source = "defmodule D do\n  def f(x \\\\ 1 + 2), do: x\nend\n"
    {_meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    assert [%Site{mutator: :arithmetic, original_op: :+}] = sites
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
    {meta, sites, _next_id} = Mutare.transform_string(source)

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
    {meta, sites, _next_id} = Mutare.transform_string(source)

    refute Enum.any?(sites, &(&1.line in 2..4))
    assert Enum.any?(sites, &(&1.line == 6))
    # The `only:` list rides through verbatim — no selector wrapped around it.
    assert meta =~ "only: [first: 1]"
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "a case-clause guard is not mutated in place; the clause body is" do
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

    {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    # A case-clause guard is not a def/defp guard (lifting only applies to
    # those), and a `case` can't live in a guard — so `n > 1` stays unmutated.
    # The clause body `n + 1` mutates in place.
    assert [%Site{mutator: :arithmetic, original_op: :+, kind: :in_place}] = sites
    refute meta =~ "when (case"
    refute meta =~ "when case"
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  test "comprehension filters and bodies mutate; the generator pattern does not" do
    source = "defmodule F do\n  def f(xs), do: for(x <- xs, x > 0, do: x + 1)\nend\n"
    {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    # Filter `x > 0` (2 relational swaps) and body `x + 1` (1 swap) both mutate;
    # the generator pattern `x` does not.
    assert Enum.frequencies_by(sites, & &1.original_op) == %{:> => 2, :+ => 1}
    assert {:ok, _} = Code.string_to_quoted(meta)
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

    {_meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    # The `->` left side in a `cond` is a runtime condition, not a pattern.
    assert Enum.frequencies_by(sites, & &1.original_op) == %{:> => 2}
  end

  test "with/else blocks are walked without corrupting the metamutant" do
    source = """
    defmodule W do
      def f(m) do
        with {:ok, n} <- m do
          n + 1
        else
          _ -> 0
        end
      end
    end
    """

    {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @probe)

    assert [%Site{mutator: :arithmetic, original_op: :+}] = sites
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  describe "match?/2 pattern-context routing" do
    test "the first arg is a pattern (literals there are not mutated); the matched expr is runtime" do
      source = """
      defmodule MatchQ do
        def f(s, n) do
          match?("x" <> _, s) and n + 1 > 0
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.transform_string(source, mutators: @probe ++ [Mutare.Mutators.StringLiteral])

      # The string `"x"` lives in the `match?` pattern, so it is never offered to a
      # mutator (splicing a selector there is "case not allowed in matches"). The
      # runtime `n + 1`/`> 0` around it still mutate.
      assert Enum.frequencies_by(sites, & &1.mutator) == %{arithmetic: 1, relational: 2}
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a literal inside a tuple pattern in match? is still not mutated" do
      source = """
      defmodule MatchTuple do
        def f(pair), do: match?({"_" <> _v, _m}, pair)
      end
      """

      {_meta, sites, _next_id} =
        Mutare.transform_string(source,
          mutators: [Mutare.Mutators.StringLiteral, Mutare.Mutators.TupleLiteral]
        )

      # No string-empty/tuple-empty mutation reaches the match? pattern.
      assert sites == []
    end
  end

  describe "a selector cannot be a bare pipe target (|> hoisting)" do
    # `x |> case … end` *parses* but fails to compile (`Kernel.|>/2` can't pipe into
    # a `case`), so these assert the metamutant **compiles**, not just parses.
    test "a mutated middle/first pipe stage compiles" do
      source = """
      defmodule PipeFirst do
        def f(xs), do: xs |> Enum.reject(& &1) |> Enum.map(& &1)
      end
      """

      {meta, sites, _next_id} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.Collection])

      assert Enum.any?(sites, &(&1.mutator == :collection))
      # The diff still shows the bare stage swap, not the whole pipe.
      assert Enum.any?(sites, &(&1.mutated_code == "Enum.filter(& &1)"))
      assert_compiles(meta)
    end

    test "a mutated last pipe stage that is also the function tail compiles" do
      source = """
      defmodule PipeTail do
        def f(xs), do: xs |> Enum.map(& &1) |> Enum.reject(& &1)
      end
      """

      # Collection swaps the trailing `Enum.reject`; ReturnValue additionally wraps
      # the whole tail pipe — so the selector lands in the ReturnValue catch-all.
      {meta, _sites, _next_id} =
        Mutare.transform_string(source,
          mutators: [Mutare.Mutators.Collection, Mutare.Mutators.ReturnValue]
        )

      assert_compiles(meta)
    end
  end

  describe "atom-literal context routing (keys and patterns are not mutated)" do
    @atom [Mutare.Mutators.AtomLiteral]

    test "value atoms mutate but keyword/map keys do not — and it renders" do
      source = """
      defmodule K do
        def f(x), do: %{status: :active, a: :b}
        def g(x), do: foo(x, timeout: :infinity)
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @atom)

      # Values :active, :b, :infinity mutate (3); keys status/a/timeout do not.
      assert length(sites) == 3
      assert Enum.all?(sites, &(&1.mutator == :atom))
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a `do:` block key is never mutated (it would otherwise fail to render)" do
      # Regression: a selector spliced into a `case`/`if` `do:` key is malformed
      # and crashed Sourceror's formatter outright (not even poison-recoverable).
      source = """
      defmodule B do
        def f(x) do
          case x do
            :ok -> :done
            _ -> :error
          end
        end

        def g(x), do: if(x, do: :yes, else: :no)
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @atom)

      # case bodies :done/:error + if values :yes/:no mutate (4); the :ok pattern
      # and the do:/else: keys do not.
      assert length(sites) == 4
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "case/fn/with/for/receive clause patterns are not mutated; bodies are" do
      source = """
      defmodule P do
        def a(x) do
          case x do
            :ok -> :done
          end
        end

        def b, do: Enum.map([], fn :ok -> :a end)
        def c(l), do: for(:ok <- l, do: :hit)

        def d do
          with :ok <- run() do
            :done
          else
            :bad -> :err
          end
        end

        def e do
          receive do
            :msg -> :got
          end
        end
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @atom)

      # Exactly the body atoms mutate; every `:ok`/`:bad`/`:msg` pattern is skipped.
      # a:[:done] b:[:a] c:[:hit] d:[:done,:err] e:[:got] = 6 sites, no pattern atom.
      assert length(sites) == 6
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a struct's field map is not emptied, but its field values still mutate" do
      source = """
      defmodule S do
        def f, do: %User{name: :bob}
      end
      """

      {meta, sites, _next_id} =
        Mutare.transform_string(source,
          mutators: [Mutare.Mutators.MapLiteral, Mutare.Mutators.AtomLiteral]
        )

      # No :map site (the struct's `%{}` wrapper is not offered); the field value
      # :bob still gets an :atom site.
      assert Enum.frequencies_by(sites, & &1.mutator) == %{atom: 1}
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a standalone map literal IS emptied" do
      source = "defmodule M do\n  def f, do: %{a: 1}\nend\n"

      {_meta, sites, _next_id} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.MapLiteral])

      assert [%Site{mutator: :map}] = sites
    end

    test "a literal in a case-clause pattern no longer poisons (latent-bug fix)" do
      # Previously the `1` pattern was mutated into an illegal `case`-in-pattern and
      # poison-recovered; now it is routed as a pattern and never offered.
      source = """
      defmodule L do
        def f(x) do
          case x do
            1 -> :a
            _ -> :b
          end
        end
      end
      """

      {_meta, sites, _next_id} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.Literal])

      assert sites == []
    end
  end

  describe "alias context routing (value vs. module/name position)" do
    @alias [Mutare.Mutators.AliasLiteral]

    test "an alias used as a value mutates; the call-module position does not" do
      source = """
      defmodule D do
        def run, do: apply(Greeter, :hello, [])
        def direct, do: Greeter.hello()
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @alias)

      # apply(Greeter, …) → Greeter is a value (1 site); Greeter.hello() is a
      # call-module position (opaque form) and is not offered.
      assert [%Site{mutator: :alias, line: 2}] = sites
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "struct names and directives are not mutated; value args are" do
      source = """
      defmodule D do
        alias Foo.Bar
        def f(x), do: %Bar{a: x}
        def g(x), do: struct(Bar, a: x)
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @alias)

      # The `alias` directive and the `%Bar{}` struct name are excluded; only the
      # `struct(Bar, …)` value argument mutates.
      assert [%Site{mutator: :alias, line: 4}] = sites
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "defimpl/defprotocol/defdelegate module references are not mutated (poison-clean)" do
      source = """
      defmodule D do
        defdelegate foo(x), to: Helper
      end

      defprotocol P do
        def encode(x)
      end

      defimpl P, for: Foo do
        def encode(x), do: apply(Helper, :run, [x])
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @alias)

      # The defdelegate `to:`, the protocol name, and the `for:` type are excluded;
      # the defimpl *body* still mutates its value alias `Helper`.
      assert [%Site{mutator: :alias}] = sites
      assert meta =~ "defimpl P, for: Foo"
      assert {:ok, _} = Code.string_to_quoted(meta)
    end
  end

  describe "head-pattern literal lifting" do
    @literal [Mutare.Mutators.Literal]

    test "a literal in a def head is mutated by lifting (not in place)" do
      # A `case` selector is illegal in a pattern, so a head literal can only be
      # mutated by duplicating the clause group — like a guard. A single-clause
      # function with no guard now lifts solely to carry the head mutant.
      source = "defmodule H do\n  def f(1), do: :ok\nend\n"
      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @literal)

      assert [
               %Site{mutator: :literal, kind: :lifted, original_code: "1", mutated_code: "2"},
               %Site{mutator: :literal, kind: :lifted, original_code: "1", mutated_code: "0"}
             ] =
               Enum.sort_by(sites, & &1.id)

      assert meta =~ "def f(mutare_arg1) do"
      assert [{H, _}] = Code.compile_string(meta)
    end

    test "both the key and the value of a map pattern mutate (%{1 => 2})" do
      source = "defmodule H do\n  def f(%{1 => 2}), do: :ok\nend\n"
      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @literal)

      # the `1` key → {2, 0}; the `2` value → {3, 1, 0}; both lifted, none in place.
      assert Enum.all?(sites, &(&1.kind == :lifted and &1.mutator == :literal))

      assert MapSet.new(sites, &{&1.original_code, &1.mutated_code}) ==
               MapSet.new([{"1", "2"}, {"1", "0"}, {"2", "3"}, {"2", "1"}, {"2", "0"}])

      assert [{H, _}] = Code.compile_string(meta)
    end

    test "a key mutation that would duplicate a sibling key is dropped (not poisoned)" do
      # `%{1 => a, 0 => b}`: `1 → 0` and `0 → 1` would each make a duplicate map key
      # (a compile error). We detect the collision and drop just those mutations,
      # rather than emitting them and relying on poison recovery — the rest survive.
      source = "defmodule H do\n  def f(%{1 => a, 0 => b}), do: {a, b}\nend\n"
      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @literal)

      pairs = MapSet.new(sites, &{&1.original_code, &1.mutated_code})
      # the non-colliding mutations remain...
      assert MapSet.member?(pairs, {"1", "2"})
      assert MapSet.member?(pairs, {"0", "-1"})
      # ...and the colliding ones (1 → 0, 0 → 1) are gone.
      refute MapSet.member?(pairs, {"1", "0"})
      refute MapSet.member?(pairs, {"0", "1"})

      # The proof it mattered: the metamutant compiles (a duplicate key would not).
      assert [{H, _}] = Code.compile_string(meta)
    end

    test "a bitstring type specifier in a head is not mutated (it could be illegal)" do
      # The value side mutates, but the spec side (`size(8)`) is skipped: a `unit(0)`
      # / `size`-literal swap risks an illegal specifier that would poison the build.
      source = "defmodule H do\n  def f(<<8::size(8)>>), do: :ok\nend\n"
      {_meta, sites, _next_id} = Mutare.transform_string(source, mutators: @literal)

      # Only the value `8` (left of `::`) mutates; the spec `size(8)` is untouched.
      assert [
               %Site{kind: :lifted, original_code: "8", mutated_code: "9"},
               %Site{kind: :lifted, original_code: "8", mutated_code: "7"},
               %Site{kind: :lifted, original_code: "8", mutated_code: "0"}
             ] =
               Enum.sort_by(sites, & &1.id)
    end

    test "a keyword/map key in a head is a label and is not mutated" do
      source = "defmodule H do\n  def f(%{a: 1}), do: :ok\nend\n"
      {_meta, sites, _next_id} = Mutare.transform_string(source, mutators: @literal)

      # The `:a` key is skipped; only the `1` value lifts.
      assert MapSet.new(sites, & &1.mutated_code) == MapSet.new(["2", "0"])
    end

    test "head literals and guard operators lift together, sharing the dispatcher" do
      source = """
      defmodule H do
        def f(0, x) when x > 0, do: :a
        def f(_, _), do: :b
      end
      """

      {meta, sites, _next_id} =
        Mutare.transform_string(source,
          mutators: [Mutare.Mutators.Literal, Mutare.Mutators.Relational]
        )

      lifted = Enum.filter(sites, &(&1.kind == :lifted and &1.operation == :replace))
      # guard `>` → {>=, <} (relational); head `0` → {1, -1} (literal). Both lifted.
      assert Enum.any?(lifted, &(&1.mutator == :relational and &1.original_op == :>))
      assert Enum.any?(lifted, &(&1.mutator == :literal and &1.original_code == "0"))

      assert meta =~ ~r/def f\(mutare_arg1, mutare_arg2\) do/
      assert [{H, _}] = Code.compile_string(meta)
    end

    test "a non-liftable function (default arg) gets no head-literal mutant" do
      # Default args expand to multiple arities, so the group is not lifted — and a
      # head literal there falls back to the in-place `:pattern` routing, unmutated.
      source = "defmodule H do\n  def f(1, b \\\\ 2), do: b\nend\n"
      {meta, sites, _next_id} = Mutare.transform_string(source, mutators: @literal)

      refute meta =~ "__mutare_f"
      # Only the default value `2` (runtime) mutates; the head `1` does not.
      assert MapSet.new(sites, &{&1.original_code, &1.kind}) ==
               MapSet.new([{"2", :in_place}])
    end

    test "a mutator that would emit a pattern-illegal node is filtered out of heads" do
      # The compile-safety net: only literal-valued mutations survive in a pattern.
      # This mutator rewrites an integer to `n + 1` (an operator — illegal in a
      # pattern), so it must produce no *head* site (and the metamutant compiles),
      # while still mutating the same literal in a body position.
      source = "defmodule H do\n  def f(1), do: 9\nend\n"

      {meta, sites, _next_id} =
        Mutare.transform_string(source, mutators: [Mutare.TransformTest.PlusOneMutator])

      # No lifted head site — the `1` head mutant was filtered (would not compile).
      refute Enum.any?(sites, &(&1.kind == :lifted))
      # The body `9` still mutates in place.
      assert [%Site{kind: :in_place, original_code: "9"}] = sites
      assert [{H, _}] = Code.compile_string(meta)
    end
  end

  test "the default set fires the expanded families (logical, literal, conditional, …)" do
    source = """
    defmodule D do
      def f(a, b), do: a and b + 1
      def flag, do: true
    end
    """

    {meta, sites, _next_id} = Mutare.transform_string(source)
    by = Enum.frequencies_by(sites, & &1.mutator)

    # b + 1 → b - 1
    assert by[:arithmetic] == 1
    # a and _ → a or _
    assert by[:logical] == 1
    # (a and _) → true / false
    assert by[:conditional] == 2
    # 1 → {2, 0}; true → false
    assert by[:literal] == 3
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  describe "coverage helper xref warning" do
    # The selector catch-alls call `:mutare_cov.hit/1`, a helper that in an umbrella
    # lives in a generated sibling app the mutated app declares no dep on — so it
    # may be compiled later and draw a benign "undefined function" xref warning.
    # `Transform` prepends `@compile {:no_warn_undefined, …}` to every module body
    # to silence it; the call still resolves at runtime. (Suppression itself can
    # only be observed where the helper is absent — Mutare's own VM ships a
    # `:mutare_cov` test stand-in — so the end-to-end check lives in
    # `Mutare.UmbrellaTest`; here we pin that the attribute is emitted, per module.)
    @attr "@compile {:no_warn_undefined, {#{inspect(Mutare.Coverage.Recorder.helper_module())}, :hit, 1}}"

    @multi_module """
    defmodule Outer do
      defmodule Inner do
        def add(a, b), do: a + b
      end

      def sub(a, b), do: a - b
    end

    defimpl String.Chars, for: Outer do
      def to_string(_), do: "a" <> "b"
    end
    """

    test "every module (incl. nested and defimpl) carries the no-warn attribute" do
      {meta, _sites, _next_id} = Mutare.transform_string(@multi_module)

      # One per module body: Outer, Inner, and the String.Chars impl.
      occurrences = meta |> String.split(@attr) |> length() |> Kernel.-(1)
      assert occurrences == 3
      assert {:ok, _ast} = Code.string_to_quoted(meta)
    end

    test "the attribute targets exactly the MFA the catch-all calls (no drift)" do
      # If the helper module/arity ever drifts from what `record_ast/1` emits, the
      # attribute would stop matching the call and the warning would silently
      # return — so assert both reference the same `<helper>.hit(...)`.
      helper = inspect(Mutare.Coverage.Recorder.helper_module())

      {meta, _sites, _next_id} =
        Mutare.transform_string("defmodule M do\n  def f(a, b), do: a + b\nend\n")

      assert meta =~ "#{helper}.hit("
      assert meta =~ @attr
    end
  end

  # Assert the metamutant actually *compiles*. A bug like a selector `case` spliced
  # as a bare pipe target parses cleanly but fails at compile (macro expansion), so
  # `Code.string_to_quoted/1` is not enough. The `:mutare_cov` test stand-in and
  # `:persistent_term` make the selector/coverage calls resolvable; stderr (e.g.
  # redefinition notices) is swallowed.
  defp assert_compiles(meta) do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert [_ | _] = Code.compile_string(meta)
    end)
  end
end
