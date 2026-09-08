defmodule Mutare.Transform.FnClauseEmitTest do
  use ExUnit.Case, async: false

  alias Mutare.Coverage.Recorder
  alias Mutare.{Manifest, Selector, Transform}

  defmodule CoverageSink do
    def hit(ids) do
      send(self(), {:covered, ids})
      true
    end
  end

  defmodule WholeFn do
    @behaviour Mutare.Mutator
    def name, do: :whole_fn
    def mutate({:fn, _, _}), do: [Mutare.AST.literal(:replaced)]
    def mutate(_), do: :skip
  end

  defmodule PoisonGuard do
    @behaviour Mutare.Mutator
    def name, do: :poison_fn_guard
    def mutate({:>, _, [x, _]}), do: [quote(do: Map.new(unquote(x)))]
    def mutate(_), do: :skip
  end

  setup do
    previous = :persistent_term.get(Recorder.track_key(), false)
    Selector.put(Selector.baseline())
    :persistent_term.put(Recorder.track_key(), false)

    on_exit(fn ->
      Selector.put(Selector.baseline())
      :persistent_term.put(Recorder.track_key(), previous)
    end)

    :ok
  end

  test "one fn and C+M clauses; coverage ids occur once as clause count doubles" do
    sizes =
      for count <- [20, 40] do
        clauses = Enum.map_join(1..count, "\n", &"#{&1} -> :matched")
        {_, sites, metamutant} = compile_fixture(:Growth, "def make, do: fn\n#{clauses}\nend")
        assert [clauses] = fn_clauses(metamutant)
        assert length(clauses) == count + length(sites)
        assert coverage_payloads(metamutant) == [Enum.map(sites, & &1.id)]
        byte_size(metamutant)
      end

    [small, large] = sizes
    assert large < small * 2.2
  end

  test "every mutant agrees with its source patch, including precedence and multi-arg OR guards" do
    body = """
    def make do
      fn
        :early, v -> {:early, v}
        1, v when is_integer(v) and v > 5 when is_binary(v) -> {:first, v}
        2, v -> {:second, v}
        {a, a}, v -> {:same, a, v}
        {a, b}, v -> {:pair, a, b, v}
      end
    end
    """

    mutators = [
      Mutare.Mutators.IntegerLiteral,
      Mutare.Mutators.Relational,
      Mutare.Mutators.PatternSwap,
      Mutare.Mutators.PatternWildcard
    ]

    {module, sites, _} = compile_fixture(:Equivalence, body, mutators)
    source = source(module, body)
    assert Enum.any?(sites, &(&1.mutator == :pattern_swap))
    assert Enum.any?(sites, &(&1.mutator == :pattern_wildcard))
    assert Enum.any?(sites, &(&1.mutator == :relational))

    for site <- [nil | sites] do
      patched =
        if site,
          do: Sourceror.patch_string(source, [%{range: site.range, change: site.mutated_code}]),
          else: source

      {:defmodule, _, [_, [do: {:def, _, [_, [do: expression]]}]]} =
        Code.string_to_quoted!(patched)

      {expected, _} = Code.eval_quoted(expression)
      Selector.put(if site, do: site.id, else: 999_999)
      actual = apply(module, :make, [])
      assert is_function(actual, 2)

      for x <- [:early, :missing, 0, 1, 2, 3, {1, 1}, {1, 2}], y <- [4, 5, 6, "text", nil] do
        assert outcome(actual, [x, y]) == outcome(expected, [x, y]),
               "mutant #{inspect(site && site.id)}, args #{inspect([x, y])}"
      end
    end
  end

  test "records all heads on creation, with body coverage only when invoked" do
    {module, sites, _} = compile_fixture(:Coverage, "def make, do: fn 1 -> 100; 2 -> 200 end")
    :persistent_term.put(Recorder.track_key(), true)
    ids_for = fn codes -> for site <- sites, site.original_code in codes, do: site.id end
    heads = ids_for.(["1", "2"])
    first_body = ids_for.(["100"])

    fun = apply(module, :make, [])
    assert_receive {:covered, ^heads}
    refute_receive {:covered, _}
    assert_raise FunctionClauseError, fn -> fun.(:missing) end
    refute_receive {:covered, _}
    assert fun.(1) == 100
    assert_receive {:covered, ^first_body}
    refute_receive {:covered, _}

    retarget = site(sites, "1", "2")
    Selector.put(retarget.id)
    mutant = apply(module, :make, [])
    refute_receive {:covered, _}
    assert mutant.(2) == 100
    refute_receive {:covered, _}
  end

  test "captures selection for baseline, head mutants and body mutants, including nested closures" do
    {module, sites, _} =
      compile_fixture(
        :Captured,
        "def make, do: fn 1 -> fn 2 -> 100 end; 3 -> fn 4 -> 200 end end"
      )

    baseline = apply(module, :make, [])
    Selector.put(site(sites, "1", "2").id)
    outer_mutant = apply(module, :make, [])
    Selector.put(site(sites, "2", "3").id)
    inner_mutant = apply(module, :make, [])
    Selector.put(site(sites, "100", "101").id)
    body_mutant = apply(module, :make, [])
    Selector.put(Selector.baseline())

    assert baseline.(1).(2) == 100
    assert outer_mutant.(2).(2) == 100
    assert_raise FunctionClauseError, fn -> outer_mutant.(1) end
    assert inner_mutant.(1).(3) == 100
    assert_raise FunctionClauseError, fn -> inner_mutant.(1).(2) end
    assert body_mutant.(1).(2) == 101
    assert body_mutant.(3).(4) == 200
  end

  test "pins and captured variables survive; arity-zero fn bodies still mutate" do
    {module, sites, _} =
      compile_fixture(:Pins, """
      def make(value), do: fn
        ^value, 1 -> {:pinned, value}
        _, 2 -> :fallback
      end
      def zero, do: fn -> 100 end
      """)

    Selector.put(site(sites, "1", "2").id)
    fun = apply(module, :make, [:kept])
    assert is_function(fun, 2)
    assert fun.(:kept, 2) == {:pinned, :kept}
    assert fun.(:other, 2) == :fallback
    assert_raise FunctionClauseError, fn -> fun.(:kept, 1) end
    Selector.put(site(sites, "100", "101").id)
    zero = apply(module, :zero, [])
    assert is_function(zero, 0)
    assert zero.() == 101
  end

  test "existing bindings and macro caller scope survive in original and raw mutant bodies" do
    {module, sites, metamutant} =
      compile_fixture(:Scope, """
      defmacro scope do
        Macro.escape({Macro.Env.vars(__CALLER__), __CALLER__.function})
      end
      def make(mutare_active), do: fn
        1 -> {binding(), scope()}
        2 -> {binding(), scope()}
      end
      """)

    assert [clauses] = fn_clauses(metamutant)
    assert length(clauses) == 2 + length(sites)
    assert metamutant =~ "mutare_active_0"

    for id <- [0 | Enum.map(sites, & &1.id)] do
      Selector.put(id)
      fun = apply(module, :make, [:source_value])

      for arg <- [0, 1, 2, 3] do
        case outcome(fun, [arg]) do
          {:ok, {bindings, {vars, {:make, 1}}}} ->
            assert bindings[:mutare_active] == :source_value
            assert bindings[:mutare_active_0] == id
            assert Enum.sort(vars) == [mutare_active: nil, mutare_active_0: nil]

          :function_clause ->
            :ok
        end
      end
    end
  end

  test "unbound default scopes retain whole-fn delivery and raw mutant macro bindings" do
    {module, sites, metamutant} =
      compile_fixture(:Default, ~S"""
      defmacro scope, do: Macro.escape(Macro.Env.vars(__CALLER__))
      def make(fun \\ fn 1 -> scope(); 2 -> scope() end), do: fun
      """)

    assert length(fn_clauses(metamutant)) == 1 + length(sites)
    assert apply(module, :make, []).(1) == [mutare_active: nil]
    Selector.put(site(sites, "1", "2").id)
    fun = apply(module, :make, [])
    Selector.put(Selector.baseline())
    assert fun.(2) == []
    assert_raise FunctionClauseError, fn -> fun.(1) end
  end

  test "fn creation inside a shorthand capture stays legal and captures the selector" do
    {module, sites, _} =
      compile_fixture(:Capture, "def make, do: &Enum.map(&1, fn 1 -> :one; _ -> :other end)")

    baseline = apply(module, :make, [])
    Selector.put(site(sites, "1", "2").id)
    mutant = apply(module, :make, [])
    Selector.put(Selector.baseline())
    assert baseline.([1, 2]) == [:one, :other]
    assert mutant.([1, 2]) == [:other, :one]
  end

  test "unbound fn head mutants keep raw scope alongside whole-node and return mutants" do
    {module, sites, _} =
      compile_fixture(
        :RescueScope,
        """
        defmacro scope, do: Macro.escape(Macro.Env.vars(__CALLER__))
        def make do
          raise "enter rescue"
        rescue
          _ -> fn 1 -> scope(); 2 -> scope() end
        end
        """,
        [WholeFn, Mutare.Mutators.IntegerLiteral, Mutare.Mutators.ReturnValue]
      )

    assert apply(module, :make, []).(1) == [mutare_active: nil]
    Selector.put(site(sites, "1", "2").id)
    fun = apply(module, :make, [])
    Selector.put(Selector.baseline())
    assert fun.(2) == []
    assert_raise FunctionClauseError, fn -> fun.(1) end

    whole = Enum.find(sites, &(&1.mutator == :whole_fn))
    Selector.put(whole.id)
    assert apply(module, :make, []) == :replaced

    returns =
      Enum.filter(
        sites,
        &(&1.mutator == :return_value and String.starts_with?(&1.original_code, "fn"))
      )

    assert returns != []

    for tail <- returns do
      Selector.put(tail.id)
      {expected, _} = Code.eval_string(tail.mutated_code)
      assert apply(module, :make, []) == expected
    end
  end

  test "nested module bodies cannot capture an outer function's selector" do
    nested = Module.concat(__MODULE__, :Nested)

    {module, sites, metamutant} =
      compile_fixture(:NestedOwner, """
      def build do
        defmodule Elixir.#{inspect(nested)} do
          def make, do: fn 1 -> :one; 2 -> :two end
        end
      end
      """)

    assert length(fn_clauses(metamutant)) == 1 + length(sites)
    ExUnit.CaptureIO.capture_io(:stderr, fn -> apply(module, :build, []) end)

    on_exit(fn ->
      :code.purge(nested)
      :code.delete(nested)
    end)

    Selector.put(site(sites, "1", "2").id)
    fun = apply(nested, :make, [])
    Selector.put(Selector.baseline())
    assert fun.(2) == :one
    assert_raise FunctionClauseError, fn -> fun.(1) end
  end

  test "custom whole-fn mutations keep their order and bypass clause delivery" do
    {module, sites, _} =
      compile_fixture(:Whole, "def make, do: fn 1 -> :one; 2 -> :two end", [
        WholeFn,
        Mutare.Mutators.IntegerLiteral
      ])

    assert [%{mutator: :whole_fn} = whole | heads] = sites
    assert Enum.all?(heads, &(&1.mutator == :integer))
    Selector.put(whole.id)
    assert apply(module, :make, []) == :replaced
    Selector.put(site(sites, "1", "2").id)
    assert apply(module, :make, []).(2) == :one
  end

  test "whole-fn return replacements keep their ids after clause candidates" do
    {module, sites, _} =
      compile_fixture(:ReturnOrder, "def make, do: fn 1 -> :one; 2 -> :two end", [
        WholeFn,
        Mutare.Mutators.IntegerLiteral,
        Mutare.Mutators.ReturnValue
      ])

    whole = Enum.find(sites, &(&1.mutator == :whole_fn))
    heads = Enum.filter(sites, &(&1.mutator == :integer))

    returns =
      Enum.filter(
        sites,
        &(&1.mutator == :return_value and String.starts_with?(&1.original_code, "fn"))
      )

    assert returns != []
    assert Enum.all?(heads, &(&1.id > whole.id))
    assert Enum.all?(returns, &(&1.id > List.last(heads).id))

    for tail <- returns do
      Selector.put(tail.id)
      {expected, _} = Code.eval_string(tail.mutated_code)
      assert apply(module, :make, []) == expected
    end
  end

  test "poison skips, ignores and selection retain ids and exclude only live variants" do
    body = """
    def make, do: fn
      1 -> :one # mutare:ignore[integer:zero] intentional
      2 -> :two
      3 -> :three
    end
    """

    module = Module.concat(__MODULE__, :Filtered)
    source = source(module, body)
    opts = [mutators: [Mutare.Mutators.IntegerLiteral], start_id: 50]
    {_, original_sites, next} = Transform.transform_string_with_sites(source, opts)
    skipped = site(original_sites, "2", "3").id
    selected = for s <- original_sites, s.original_code != "3", into: MapSet.new(), do: s.id
    filtered = opts ++ [skip_ids: MapSet.new([skipped]), emit_ids: selected]
    {metamutant, sites, ^next} = Transform.transform_string_with_sites(source, filtered)
    assert Enum.map(sites, &{&1.id, &1.range}) == Enum.map(original_sites, &{&1.id, &1.range})
    assert Transform.count_string(source, filtered) == length(sites)
    live = for s <- sites, not s.ignored and not s.poisoned and s.id in selected, do: s.id
    assert coverage_payloads(metamutant) == [live]
    assert [clauses] = fn_clauses(metamutant)
    assert length(clauses) == 3 + length(live)
    compile_observed(module, metamutant)

    for id <- [skipped | Enum.map(Enum.filter(sites, & &1.ignored), & &1.id)] do
      Selector.put(id)
      fun = apply(module, :make, [])
      assert fun.(1) == :one
      assert fun.(2) == :two
      assert fun.(3) == :three
    end

    {unchanged, _, ^next} =
      Transform.transform_string_with_sites(source, opts ++ [emit_ids: MapSet.new()])

    assert unchanged == source
  end

  test "manifest attributes fn heads and structural fallback, then a poison skip compiles" do
    module = Module.concat(__MODULE__, :Poison)
    source = source(module, "def make(mutare_active), do: fn x when x > 5 -> x; _ -> :other end")
    opts = [mutators: [PoisonGuard, Mutare.Mutators.IntegerLiteral]]
    {metamutant, sites, next} = Transform.transform_string_with_sites(source, opts)
    poison = Enum.find(sites, &(&1.mutator == :poison_fn_guard))
    manifest = Manifest.from_source(metamutant)
    line = line_of(metamutant, "Map.new(x)")
    assert Manifest.ids_at_line(manifest, line) == [poison.id]

    assert Enum.sort(Manifest.ids_at_line(manifest, line_of(metamutant, "fn"))) ==
             Enum.map(sites, & &1.id)

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise CompileError, fn -> Code.compile_string(metamutant) end
    end)

    {recovered, recovered_sites, ^next} =
      Transform.transform_string_with_sites(source, opts ++ [skip_ids: MapSet.new([poison.id])])

    assert Enum.find(recovered_sites, &(&1.id == poison.id)).poisoned
    compile_observed(module, recovered)
    assert apply(module, :make, [:source]).(6) == 6
  end

  defp outcome(fun, args) do
    {:ok, apply(fun, args)}
  rescue
    FunctionClauseError -> :function_clause
  end

  defp site(sites, original, mutated) do
    found = Enum.find(sites, &(&1.original_code == original and &1.mutated_code == mutated))
    assert found, "missing #{original} -> #{mutated}"
    found
  end

  defp source(module, body), do: "defmodule #{inspect(module)} do\n#{body}\nend"

  defp compile_fixture(name, body, mutators \\ [Mutare.Mutators.IntegerLiteral]) do
    module = Module.concat(__MODULE__, name)

    {metamutant, sites, _} =
      Transform.transform_string_with_sites(source(module, body), mutators: mutators)

    compile_observed(module, metamutant)
    {module, sites, metamutant}
  end

  defp compile_observed(module, metamutant) do
    observed = String.replace(metamutant, ":mutare_cov.hit(", "#{inspect(CoverageSink)}.hit(")
    ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(observed) end)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp fn_clauses(source) do
    {_, clauses} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:fn, _, clauses} = node, acc -> {node, [clauses | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(clauses)
  end

  defp coverage_payloads(source) do
    {_, payloads} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [:mutare_cov, :hit]}, _, [ids]} = node, acc -> {node, [ids | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(payloads)
  end

  defp line_of(source, fragment),
    do: Enum.find_index(String.split(source, "\n"), &String.contains?(&1, fragment)) + 1
end
