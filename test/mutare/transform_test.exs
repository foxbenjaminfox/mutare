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
end
