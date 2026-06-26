defmodule Mutare.ReturnValueTest do
  @moduledoc """
  Return-value mutation: replace a `def`/`defp` clause's tail expression with a
  constant. Structural (the transform names the tail), delivered by the in-place
  selector, on by default.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Mutare.Mutators.ReturnValue
  alias Mutare.{Selector, Site}

  @compile {:no_warn_undefined, Mutare.ReturnValueFixture}

  # Isolate the family: with only ReturnValue enabled, the *only* operator-free
  # sites are return mutants (clause-drop is structural and still appears for
  # multi-clause groups, so filter to :return_value when a group lifts).
  @only [ReturnValue]

  # One compile for the runtime-semantics tests below; behavior then changes only
  # by flipping `:persistent_term` (the central bet). The other describe blocks
  # don't use `sites` — they call `return_sites/1` directly.
  @runtime_source """
  defmodule Mutare.ReturnValueFixture do
    def add(a, b), do: a + b
    def tag, do: :ok
  end
  """

  setup_all do
    {metamutant, sites, _} = Mutare.transform_string(@runtime_source, mutators: @only)
    [{_module, _binary}] = Code.compile_string(metamutant)
    %{sites: sites}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  # Return-value sites for a one-line function body `def f(a, b), do: <tail>`.
  defp return_sites(tail) do
    {_meta, sites, _} =
      Mutare.transform_string("defmodule T do\n  def f(a, b), do: #{tail}\nend\n",
        mutators: @only
      )

    Enum.filter(sites, &(&1.mutator == :return_value))
  end

  defp mutated_codes(tail), do: tail |> return_sites() |> Enum.map(& &1.mutated_code)

  describe "return_replacements/1 (the contrasting pair, and which tails are skipped)" do
    test "a computed numeric tail becomes the pair 0 and 1" do
      assert mutated_codes("a + b") == ["0", "1"]
      assert mutated_codes("a * b") == ["0", "1"]
      assert mutated_codes("div(a, b)") == ["0", "1"]
      assert mutated_codes("-a") == ["0", "1"]
    end

    test "a string concatenation becomes \"\" and the \"mutare\" sentinel" do
      assert mutated_codes(~s("x" <> b)) == [~s(""), ~s("mutare")]
    end

    test "a list concatenation becomes [] and the [:mutare] sentinel" do
      assert mutated_codes("a ++ b") == ["[]", "[:mutare]"]
      assert mutated_codes("a -- b") == ["[]", "[:mutare]"]
    end

    test "a variable, call, tuple, map, or atom tail becomes nil and the :mutare sentinel" do
      assert mutated_codes("a") == ["nil", ":mutare"]
      assert mutated_codes("foo(a)") == ["nil", ":mutare"]
      assert mutated_codes("{:ok, a}") == ["nil", ":mutare"]
      assert mutated_codes("%{a: a}") == ["nil", ":mutare"]
      assert mutated_codes(":ok") == ["nil", ":mutare"]
    end

    test "a sentinel equal to the tail is dropped (no equivalent mutant)" do
      # A bare `:mutare` tail would otherwise get a `:mutare` sentinel — an
      # equivalent no-op — so only the `nil` half survives. (The mirror of
      # StringLiteral dropping the half equal to its source string.)
      assert mutated_codes(":mutare") == ["nil"]
    end

    test "a boolean-valued tail is skipped (Conditional already forces true/false)" do
      assert return_sites("a > b") == []
      assert return_sites("a and b") == []
      assert return_sites("a in b") == []
      assert return_sites("not a") == []
    end

    test "a literal a value family already mutates is skipped" do
      assert return_sites("5") == []
      assert return_sites("1.5") == []
      assert return_sites(~s("hi")) == []
      assert return_sites("[1, 2]") == []
      assert return_sites("true") == []
    end

    test "a nil tail is skipped (replacing nil with nil is equivalent)" do
      assert return_sites("nil") == []
    end

    test "a quote-block tail is skipped (macro AST is left whole)" do
      assert return_sites("quote(do: x + 1)") == []
    end

    test "an empty-list / empty-string tail is its own redundant literal, skipped" do
      assert return_sites("[]") == []
      assert return_sites(~s("")) == []
    end

    test "does not implement mutate/1 — the family is structural" do
      refute function_exported?(ReturnValue, :mutate, 1)
      assert ReturnValue.name() == :return_value
    end
  end

  describe "the recorded Site" do
    test "is :return_value, :in_place, operator-free, with the right diff and line" do
      [empty, sentinel] = return_sites("a + b")

      assert %Site{
               mutator: :return_value,
               kind: :in_place,
               operation: :replace,
               original_form: nil,
               mutated_form: nil,
               original_code: "a + b",
               mutated_code: "0",
               line: 2
             } = empty

      assert %Site{mutator: :return_value, original_code: "a + b", mutated_code: "1", line: 2} =
               sentinel

      assert Site.describe(empty) == "return_value  a + b → 0"
      assert Site.describe(sentinel) == "return_value  a + b → 1"
    end
  end

  describe "which positions are targeted" do
    test "only the tail of a multi-statement body, not intermediate statements" do
      source = """
      defmodule T do
        def f(x) do
          y = x + 1
          y * 2
        end
      end
      """

      {_meta, sites, _} = Mutare.transform_string(source, mutators: @only)
      returns = Enum.filter(sites, &(&1.mutator == :return_value))

      # `y = x + 1` (line 3) is not the tail; only `y * 2` (line 4) is — and it
      # gets the contrasting pair (0 and 1).
      assert [
               %Site{line: 4, original_code: "y * 2", mutated_code: "0"},
               %Site{line: 4, original_code: "y * 2", mutated_code: "1"}
             ] = returns
    end

    test "every clause of a lifted (guarded) group gets return mutants in its original clause" do
      source = """
      defmodule T do
        def g(n) when n > 0, do: n + 1
        def g(_), do: :zero
      end
      """

      {meta, sites, _} =
        with_log(fn -> Mutare.transform_string(source, mutators: @only) end) |> elem(0)

      returns = Enum.filter(sites, &(&1.mutator == :return_value))

      # Both clause tails get the pair (n + 1 → 0/1, :zero → nil/:mutare), delivered
      # as in-place selectors in each clause's *original* (non-mutant) version inside
      # the lifted private group.
      assert MapSet.new(returns, & &1.mutated_code) == MapSet.new(["0", "1", "nil", ":mutare"])
      assert meta =~ ~r/defp __mutare_g_1_g\d+\(/
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "an operator swap and the return pair share one selector at the tail node" do
      # `a + b` is both an arithmetic site and a return-value site: one selector
      # `case` hosts all three mutant clauses (a - b, and 0, and 1).
      {meta, sites, _} =
        Mutare.transform_string("defmodule T do\n  def f(a, b), do: a + b\nend\n",
          mutators: [Mutare.Mutators.Arithmetic, ReturnValue]
        )

      assert Enum.map(sites, & &1.mutator) == [:arithmetic, :return_value, :return_value]
      # one selector subject only (all mutants live under it); count via the runtime
      # key so this holds under dogfooding (subject keyed on `Selector.suite_key/0`).
      subject = ":persistent_term.get(#{inspect(Selector.key())}"
      assert meta |> String.split(subject) |> length() == 2
      assert {:ok, _} = Code.string_to_quoted(meta)
    end
  end

  describe "return paths beyond the :do block (rescue / catch / else; after excluded)" do
    # A function body with every return-path block. The :do tail, plus each
    # rescue/catch/else clause body tail, is a return path; the after block is not
    # (try discards its value).
    @try_source """
    defmodule T do
      def f(x) do
        compute(x)
      rescue
        e in RuntimeError -> {:error, e}
      catch
        :throw, v -> v
      else
        {:ok, n} -> n + 1
      after
        cleanup(x)
      end
    end
    """

    defp try_returns do
      {_meta, sites, _} = Mutare.transform_string(@try_source, mutators: @only)
      Enum.filter(sites, &(&1.mutator == :return_value))
    end

    test "rescue, catch, and else clause tails each get the contrasting pair" do
      by_original = Enum.group_by(try_returns(), & &1.original_code, & &1.mutated_code)

      assert by_original["compute(x)"] == ["nil", ":mutare"]
      assert by_original["{:error, e}"] == ["nil", ":mutare"]
      assert by_original["v"] == ["nil", ":mutare"]
      assert by_original["n + 1"] == ["0", "1"]
    end

    test "the after block is not a return path (its value is discarded by try)" do
      refute Enum.any?(try_returns(), &(&1.original_code == "cleanup(x)"))
    end

    test "a rescue/else pattern is never mutated, so the metamutant still compiles" do
      # `e in RuntimeError` is a rescue *pattern*: a Conditional `true`/`false`
      # selector spliced there would be illegal Elixir. With the full mutator set
      # the metamutant must carry no such mutant and still compile.
      source = """
      defmodule Mutare.ReturnValueRescuePattern do
        def f(x) do
          risky(x)
        rescue
          e in RuntimeError -> handle(e)
        end

        defp risky(x), do: x
        defp handle(_), do: :err
      end
      """

      {meta, sites, _} = Mutare.transform_string(source)

      refute Enum.any?(sites, &(&1.mutator == :conditional))
      assert {:ok, _} = Code.string_to_quoted(meta)

      assert {[{Mutare.ReturnValueRescuePattern, _}], _log} =
               with_log(fn -> Code.compile_string(meta) end)
    end
  end

  describe "return-analysis mechanics (Mutare.Transform.Analyze.Returns)" do
    test "operator mutants in rescue/catch/else clause bodies survive alongside returns" do
      # `map_clauses/3` keeps the *analyzed* clause body (operator candidates and
      # all) and uses the raw copy only for the clean return diff. Swapping the two — so it
      # rebuilds from the un-analyzed `raw` body — would silently drop every operator mutant
      # inside a rescue/catch/else body. Requires both ReturnValue (to enter the clause-return
      # path at all) and an operator family (to have something to lose).
      source = """
      defmodule T do
        def f(x) do
          risky(x)
        rescue
          _ -> x + 1
        catch
          :throw, v -> v * 2
        else
          n -> n - 3
        end
      end
      """

      {_meta, sites, _} =
        Mutare.transform_string(source, mutators: [ReturnValue, Mutare.Mutators.Arithmetic])

      arith = sites |> Enum.filter(&(&1.mutator == :arithmetic)) |> Enum.map(& &1.original_code)
      assert Enum.sort(arith) == ["n - 3", "v * 2", "x + 1"]
    end

    test "the return tail of a 3+ statement body is its last statement (Enum.split/-1)" do
      # `map_return_tails/3` splits off the *last* statement with `Enum.split(stmts, -1)`. Miscoding
      # the index as `1` would split off the *first* statement and the `[last]` match would
      # raise for any 3-or-more-statement block — so this fixes the index for both the
      # analyzed and the raw split.
      source = """
      defmodule T do
        def f(x) do
          a = x + 1
          b = a + 1
          b * 3
        end
      end
      """

      {_meta, sites, _} = Mutare.transform_string(source, mutators: [ReturnValue])
      returns = Enum.filter(sites, &(&1.mutator == :return_value))

      assert returns != []
      assert Enum.all?(returns, &(&1.original_code == "b * 3"))
    end
  end

  describe "control-flow branch tails (case / cond / if / unless descended in tail position)" do
    # `{original_code => [mutated_code]}` for the return-value sites of a full
    # `def f(...) do ... end` body.
    defp branch_returns(body) do
      {_meta, sites, _} =
        Mutare.transform_string("defmodule T do\n#{body}\nend\n", mutators: @only)

      sites
      |> Enum.filter(&(&1.mutator == :return_value))
      |> Enum.group_by(& &1.original_code, & &1.mutated_code)
    end

    test "each `case` clause tail gets the pair; the construct itself is not a tail" do
      by_original =
        branch_returns("""
          def f(x) do
            case x do
              :a -> foo(x)
              :b -> {:ok, x}
            end
          end\
        """)

      # Each branch tail is a return path...
      assert by_original["foo(x)"] == ["nil", ":mutare"]
      assert by_original["{:ok, x}"] == ["nil", ":mutare"]
      # ...and the whole `case` is no longer mutated as one unit.
      refute Map.has_key?(by_original, "case x do\n  :a -> foo(x)\n  :b -> {:ok, x}\nend")
    end

    test "both `if` branches descend (do and else), each shape-directed" do
      by_original =
        branch_returns("""
          def f(x) do
            if x do
              a + b
            else
              foo(x)
            end
          end\
        """)

      assert by_original["a + b"] == ["0", "1"]
      assert by_original["foo(x)"] == ["nil", ":mutare"]
    end

    test "an `if` with no else descends only the present branch" do
      assert branch_returns("  def f(x), do: if x, do: foo(x)") == %{
               "foo(x)" => ["nil", ":mutare"]
             }
    end

    test "`unless` branches descend like `if`" do
      by_original =
        branch_returns("""
          def f(x) do
            unless x do
              foo(x)
            else
              bar(x)
            end
          end\
        """)

      assert by_original["foo(x)"] == ["nil", ":mutare"]
      assert by_original["bar(x)"] == ["nil", ":mutare"]
    end

    test "`cond` clause tails descend" do
      by_original =
        branch_returns("""
          def f(x) do
            cond do
              x > 0 -> foo(x)
              true -> bar(x)
            end
          end\
        """)

      assert by_original["foo(x)"] == ["nil", ":mutare"]
      assert by_original["bar(x)"] == ["nil", ":mutare"]
    end

    test "nested control flow descends to the innermost leaf tails" do
      by_original =
        branch_returns("""
          def f(x) do
            case x do
              :a ->
                if x, do: foo(x), else: bar(x)

              :b ->
                baz(x)
            end
          end\
        """)

      assert by_original["foo(x)"] == ["nil", ":mutare"]
      assert by_original["bar(x)"] == ["nil", ":mutare"]
      assert by_original["baz(x)"] == ["nil", ":mutare"]
    end

    test "a `case` not in tail position (bound) is not descended" do
      by_original =
        branch_returns("""
          def f(x) do
            y =
              case x do
                :a -> foo(x)
                :b -> bar(x)
              end

            baz(y)
          end\
        """)

      # Only the genuine tail (`baz(y)`) is a return path.
      assert Map.keys(by_original) == ["baz(y)"]
    end

    test "the descended metamutant still compiles" do
      source = """
      defmodule Mutare.ReturnValueBranchCompile do
        def f(x) do
          case x do
            :a -> foo(x)
            :b -> if x, do: {:ok, x}, else: :error
          end
        end

        defp foo(x), do: x
      end
      """

      {meta, _sites, _} = Mutare.transform_string(source)
      assert {:ok, _} = Code.string_to_quoted(meta)

      assert {[{Mutare.ReturnValueBranchCompile, _}], _log} =
               with_log(fn -> Code.compile_string(meta) end)
    after
      :code.purge(Mutare.ReturnValueBranchCompile)
      :code.delete(Mutare.ReturnValueBranchCompile)
    end
  end

  describe "with / try / receive branch tails (the same walk; try-after vs receive-after)" do
    test "`with` descends the do tail and each else clause tail" do
      by_original =
        branch_returns("""
          def f(x) do
            with {:ok, v} <- fetch(x) do
              use(v)
            else
              :missing -> default(x)
              e -> oops(e)
            end
          end\
        """)

      assert by_original["use(v)"] == ["nil", ":mutare"]
      assert by_original["default(x)"] == ["nil", ":mutare"]
      assert by_original["oops(e)"] == ["nil", ":mutare"]
      # the `<-` qualifier is not a return path
      refute Map.has_key?(by_original, "fetch(x)")
    end

    test "`try` descends do/rescue/catch/else tails but NOT after (its value is discarded)" do
      by_original =
        branch_returns("""
          def f(x) do
            try do
              risky(x)
            rescue
              _ -> recover(x)
            catch
              :throw, v -> caught(v)
            else
              n -> elsed(n)
            after
              cleanup(x)
            end
          end\
        """)

      assert by_original["risky(x)"] == ["nil", ":mutare"]
      assert by_original["recover(x)"] == ["nil", ":mutare"]
      assert by_original["caught(v)"] == ["nil", ":mutare"]
      assert by_original["elsed(n)"] == ["nil", ":mutare"]
      # `after` is a cleanup whose value `try` discards — not a return path.
      refute Map.has_key?(by_original, "cleanup(x)")
    end

    test "`receive` descends each do clause AND the after body (the timeout value IS returned)" do
      by_original =
        branch_returns("""
          def f(x) do
            receive do
              {:got, m} -> handle(m)
            after
              x -> timed_out(x)
            end
          end\
        """)

      assert by_original["handle(m)"] == ["nil", ":mutare"]
      # Unlike `try`, a `receive` `after` body is the construct's value on timeout.
      assert by_original["timed_out(x)"] == ["nil", ":mutare"]
    end

    test "the with/try/receive metamutant compiles" do
      source = """
      defmodule Mutare.ReturnValueWtrCompile do
        def a(x) do
          with {:ok, v} <- f(x) do
            g(v)
          else
            e -> h(e)
          end
        end

        def b(x) do
          try do
            f(x)
          rescue
            _ -> :err
          after
            f(x)
          end
        end

        def c(x) do
          receive do
            m -> m
          after
            x -> :timeout
          end
        end

        defp f(x), do: {:ok, x}
        defp g(x), do: x
        defp h(x), do: x
      end
      """

      {meta, _sites, _} = Mutare.transform_string(source)
      assert {:ok, _} = Code.string_to_quoted(meta)

      assert {[{Mutare.ReturnValueWtrCompile, _}], _log} =
               with_log(fn -> Code.compile_string(meta) end)
    after
      :code.purge(Mutare.ReturnValueWtrCompile)
      :code.delete(Mutare.ReturnValueWtrCompile)
    end
  end

  describe "anonymous function (fn) clause return tails" do
    # `{original_code => [mutated_code]}` for the return-value sites of an
    # expression `def f(xs), do: <expr>` — `<expr>` carries the `fn`(s) under test.
    defp fn_returns(expr) do
      {_meta, sites, _} =
        Mutare.transform_string("defmodule T do\n  def f(xs), do: #{expr}\nend\n",
          mutators: @only
        )

      sites
      |> Enum.filter(&(&1.mutator == :return_value))
      |> Enum.group_by(& &1.original_code, & &1.mutated_code)
    end

    test "a single-clause fn body tail gets the contrasting pair" do
      by_original = fn_returns("Enum.map(xs, fn x -> foo(x) end)")

      # The fn body `foo(x)` is now a return path of the closure...
      assert by_original["foo(x)"] == ["nil", ":mutare"]
      # ...alongside the enclosing def tail (the whole `Enum.map(...)` call).
      assert by_original["Enum.map(xs, fn x -> foo(x) end)"] == ["nil", ":mutare"]
    end

    test "each clause of a multi-clause fn gets return mutants, shape-directed" do
      by_original =
        fn_returns("""
        Enum.map(xs, fn
              x when x > 0 -> x + 1
              0 -> :zero
              _ -> bar(x)
            end)\
        """)

      assert by_original["x + 1"] == ["0", "1"]
      assert by_original[":zero"] == ["nil", ":mutare"]
      assert by_original["bar(x)"] == ["nil", ":mutare"]
    end

    test "a fn guard is not a return tail (only the body is)" do
      by_original = fn_returns("Enum.filter(xs, fn x when x > 0 -> keep(x) end)")

      assert by_original["keep(x)"] == ["nil", ":mutare"]
      refute Map.has_key?(by_original, "x > 0")
    end

    test "control flow in a fn body descends to each branch leaf tail" do
      by_original =
        fn_returns("""
        Enum.map(xs, fn x ->
              if x > 10, do: big(x), else: small(x)
            end)\
        """)

      assert by_original["big(x)"] == ["nil", ":mutare"]
      assert by_original["small(x)"] == ["nil", ":mutare"]
    end

    test "only the tail of a multi-statement fn body, not intermediate statements" do
      by_original =
        fn_returns("""
        Enum.map(xs, fn x ->
              y = x + 1
              tag(y)
            end)\
        """)

      # `y = x + 1` is a non-final statement, not the closure's return; `tag(y)` is.
      # (The enclosing def tail — the whole `Enum.map(...)` — is its own return path.)
      refute Map.has_key?(by_original, "y = x + 1")
      assert by_original["tag(y)"] == ["nil", ":mutare"]
    end

    test "ineligible fn tails are skipped, like a def tail" do
      # The boolean / literal / nil fn bodies get no return mutant (the enclosing
      # def's own tail still does — we assert only about the fn body here).
      refute Map.has_key?(fn_returns("Enum.each(xs, fn x -> x > 0 end)"), "x > 0")
      refute Map.has_key?(fn_returns("Enum.map(xs, fn x -> 5 end)"), "5")
      refute Map.has_key?(fn_returns("Enum.map(xs, fn _ -> nil end)"), "nil")
    end

    test "a fn return mutant flips the closure's result at runtime", _ctx do
      source = """
      defmodule Mutare.FnReturnRuntime do
        def tags(xs) do
          Enum.map(xs, fn
            x when rem(x, 2) == 0 -> {:even, x}
            _ -> :odd
          end)
        end
      end
      """

      {meta, sites, _} = Mutare.transform_string(source, mutators: @only)
      [{mod, _bin}] = Code.compile_string(meta)

      Selector.put(Selector.baseline())
      assert mod.tags([2, 3]) == [{:even, 2}, :odd]

      even_nil =
        Enum.find(sites, &(&1.original_code == "{:even, x}" and &1.mutated_code == "nil"))

      Selector.put(even_nil.id)
      assert mod.tags([2, 3]) == [nil, :odd]

      odd_sentinel =
        Enum.find(sites, &(&1.original_code == ":odd" and &1.mutated_code == ":mutare"))

      Selector.put(odd_sentinel.id)
      assert mod.tags([2, 3]) == [{:even, 2}, :mutare]
    after
      Selector.put(Selector.baseline())
      :code.purge(Mutare.FnReturnRuntime)
      :code.delete(Mutare.FnReturnRuntime)
    end

    test "the full-mutator-set metamutant nests fn-return + clause-pattern selectors and compiles" do
      source = """
      defmodule Mutare.FnReturnNest do
        def run(xs) do
          Enum.map(xs, fn
            x when x > 0 -> compute(x)
            _ -> :skip
          end)
        end

        defp compute(x), do: x
      end
      """

      {meta, sites, _} = Mutare.transform_string(source)
      assert Enum.any?(sites, &(&1.mutator == :return_value and &1.original_code == "compute(x)"))
      assert {:ok, _} = Code.string_to_quoted(meta)

      assert {[{Mutare.FnReturnNest, _}], _log} =
               with_log(fn -> Code.compile_string(meta) end)
    after
      :code.purge(Mutare.FnReturnNest)
      :code.delete(Mutare.FnReturnNest)
    end
  end

  describe "selection and ignore" do
    test "off when not in the :mutators list" do
      {_meta, sites, _} =
        Mutare.transform_string("defmodule T do\n  def f(a, b), do: a + b\nend\n",
          mutators: [Mutare.Mutators.Arithmetic]
        )

      refute Enum.any?(sites, &(&1.mutator == :return_value))
    end

    test "on by default (part of Mutare.Mutators.all/0)" do
      assert ReturnValue in Mutare.Mutators.all()

      {_meta, sites, _} =
        Mutare.transform_string("defmodule T do\n  def f(a, b), do: a + b\nend\n")

      assert Enum.any?(sites, &(&1.mutator == :return_value))
    end

    test "# mutare:ignore[return_value] suppresses only the return mutant" do
      source = """
      defmodule T do
        def f(a, b), do: a + b   # mutare:ignore[return_value] tested elsewhere
      end
      """

      {_meta, sites, _} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.Arithmetic, ReturnValue])

      by = Map.new(sites, &{&1.mutator, &1.ignored})
      assert by[:return_value] == true
      assert by[:arithmetic] == false
    end
  end

  describe "runtime semantics (one compile, flip the selector)" do
    test "baseline returns the real value", %{sites: _} do
      assert Mutare.ReturnValueFixture.add(2, 3) == 5
      assert Mutare.ReturnValueFixture.tag() == :ok
    end

    test "the return mutant replaces add/2's result with 0", %{sites: sites} do
      site = Enum.find(sites, &(&1.original_code == "a + b"))
      Selector.put(site.id)
      assert Mutare.ReturnValueFixture.add(2, 3) == 0
      # a sibling function is unaffected
      assert Mutare.ReturnValueFixture.tag() == :ok
    end

    test "the return mutant replaces tag/0's :ok with nil", %{sites: sites} do
      site = Enum.find(sites, &(&1.original_code == ":ok"))
      Selector.put(site.id)
      assert Mutare.ReturnValueFixture.tag() == nil
    end
  end
end
