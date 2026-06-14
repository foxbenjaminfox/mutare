defmodule Mutare.MetamutantTest do
  use ExUnit.Case, async: true

  alias Mutare.{Metamutant, Selector}

  describe "subject_ast/0 and subject?/1" do
    test "subject_ast/0 builds the persistent_term.get node Transform splices in" do
      assert Metamutant.subject_ast() ==
               {{:., [], [:persistent_term, :get]}, [], [Selector.key(), Selector.baseline()]}
    end

    test "subject?/1 recognises the subject regardless of metadata" do
      assert Metamutant.subject?(Metamutant.subject_ast())

      # A parsed selector carries line/column metadata; the predicate ignores it.
      with_meta = {{:., [line: 2], [:persistent_term, :get]}, [line: 2], [Selector.key(), 0]}
      assert Metamutant.subject?(with_meta)
    end

    test "subject?/1 rejects a different key and non-selectors" do
      refute Metamutant.subject?({{:., [], [:persistent_term, :get]}, [], [:other_key, 0]})
      refute Metamutant.subject?({:foo, [], [1, 2]})
      refute Metamutant.subject?(:not_a_node)
    end
  end

  describe "selector_clauses/1" do
    test "yields one descriptor per mutant clause, attributed to the enclosing module" do
      source = """
      defmodule Demo.Thing do
        def gte?(a, b), do: a >= b
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source, file: "lib/demo/thing.ex")
      clauses = Metamutant.selector_clauses(meta)

      # one descriptor per site, ids preserved
      assert Enum.sort(Enum.map(clauses, & &1.id)) == Enum.sort(Enum.map(sites, & &1.id))

      # all attributed to the enclosing module
      assert Enum.all?(clauses, &(&1.module == Demo.Thing))

      # an in-place selector shares one catch-all body line across its clauses,
      # while each clause carries its own (distinct) body line
      assert clauses |> Enum.map(& &1.catch_all_line) |> Enum.uniq() |> length() == 1
      assert Enum.all?(clauses, &is_integer(&1.clause_line))
      assert Enum.all?(clauses, &is_integer(&1.catch_all_line))
    end

    test "lifted dispatcher clauses share the catch-all (orig dispatch) line" do
      source = """
      defmodule Demo do
        def step(n) when n > 0, do: n + 1
        def step(_), do: 0
      end
      """

      {meta, sites, _next_id} = Mutare.transform_string(source)
      clauses = Metamutant.selector_clauses(meta)

      lifted_ids = for s <- sites, s.kind == :lifted, do: s.id

      lifted_catch_all =
        clauses
        |> Enum.filter(&(&1.id in lifted_ids))
        |> Enum.map(& &1.catch_all_line)
        |> Enum.uniq()

      assert length(lifted_catch_all) == 1
    end

    test "finds nested selectors, each attributed to the enclosing module" do
      # `+` and `==` become two nested in-place selectors (the `==` selector's
      # catch-all holds the `+` selector); the walk must reach both.
      source = """
      defmodule Demo do
        def f(a, b), do: a + b == 0
      end
      """

      {meta, _sites, _next_id} = Mutare.transform_string(source)
      clauses = Metamutant.selector_clauses(meta)

      assert length(clauses) == 2
      assert Enum.all?(clauses, &(&1.module == Demo))
    end

    test "resolves a relative nested module against its enclosing module" do
      source = """
      defmodule Outer do
        defmodule Inner do
          def add(a, b), do: a + b
        end
      end
      """

      {meta, _sites, _next_id} = Mutare.transform_string(source)
      clauses = Metamutant.selector_clauses(meta)

      assert clauses != []
      assert Enum.all?(clauses, &(&1.module == Outer.Inner))
    end
  end
end
