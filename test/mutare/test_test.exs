defmodule Mutare.TestTest do
  use ExUnit.Case, async: true

  import Mutare.Test

  alias Mutare.Mutator.Spec
  alias Mutare.Mutators.{Arithmetic, CollectionArity, Relational, ReturnValue}

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

    test "a multi-clause function surfaces the unregistered clause_drop family" do
      diffs = diffs("def f(0), do: :zero\ndef f(n), do: n + 1", [Arithmetic])

      assert {:clause_drop, "def f(0), do: :zero", ""} in diffs
      assert {:clause_drop, "def f(n), do: n + 1", ""} in diffs
      assert {:arithmetic, "n + 1", "n - 1"} in diffs
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

  describe "assert_metamutant_compiles/2" do
    test "passes for a complete module and returns the (purged) compiled modules" do
      source = "defmodule Mutare.TestTest.Sample do\n  def f(a, b), do: a + b\nend"

      compiled = assert_metamutant_compiles(source, [Arithmetic])

      assert [{module, binary} | _] = compiled
      assert is_atom(module)
      assert is_binary(binary)
      # Purged on the way out, so a second call doesn't collide.
      refute :code.is_loaded(module)
    end

    test "is callable twice for the same module without a redefinition clash" do
      source = "defmodule Mutare.TestTest.Twice do\n  def g(n), do: n * 2\nend"

      assert_metamutant_compiles(source, [Arithmetic])
      assert [_ | _] = assert_metamutant_compiles(source, [Arithmetic])
    end

    test "fails for a source that is not a complete compilation unit" do
      # No `defmodule` ⇒ the metamutant compiles to zero modules.
      assert_raise ExUnit.AssertionError, ~r/no modules/, fn ->
        assert_metamutant_compiles("x = 1 + 2", [Arithmetic])
      end
    end
  end
end
