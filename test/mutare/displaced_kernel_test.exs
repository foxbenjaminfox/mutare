defmodule Mutare.DisplacedKernelTest do
  use ExUnit.Case, async: true
  import Mutare.Test

  alias Mutare.Test.{CustomKernel, CustomNegationMutator, SourcePatch}

  test "custom module-shaped calls are not instrumented as module scopes, even under skip" do
    for form <- [:defmodule, :defimpl, :defprotocol], route <- [:skip, :raw] do
      source = source(form, 2, "#{form}(:unused, do: {:ok, 42})")
      opts = [call_routes: [{CustomKernel, form, 2, route}]]
      sites = SourcePatch.assert_patches(source, [:integer], [{:run, []}, {:other, []}], opts)
      assert Enum.all?(sites, &(&1.original_code == "123"))
      assert length(sites) == 3
    end
  end

  test "custom definitions with raw arguments are not grouped or lifted" do
    for form <- [:def, :defp] do
      source = """
      defmodule Target do
        import Kernel, except: [#{form}: 2]
        import Mutare.Test.CustomKernel, only: [#{form}: 2]
        #{form} declared(1), do: 2
      end
      """

      {[module], sites} =
        compile_metamutant(source, [:integer, :return_value],
          call_routes: [{CustomKernel, form, 2, :raw}]
        )

      assert module.__info__(:functions) == []
      assert sites == []
    end
  end

  test "boolean connectives honor pattern routes in runtime bodies" do
    for op <- [:and, :or, :&&, :||] do
      source = source(op, 2, "{:ok, 42} #{op} {:ok, 42}")
      opts = [call_routes: [{CustomKernel, op, 2, [:expression, :pattern]}]]

      sites =
        SourcePatch.assert_patches(source, [:integer, :logical, :conditional], [{:run, []}], opts)

      assert Enum.count(sites, &(&1.original_code == "42")) == 3
      assert Enum.all?(sites, &(&1.mutator == :integer))
    end
  end

  test "guard membership honors a custom macro's raw argument route" do
    source = """
    defmodule Target do
      import Kernel, except: [in: 2]
      import Mutare.Test.CustomKernel, only: [in: 2]
      def run(n) when n in {:limit, 42}, do: 1
      def run(_), do: 2
    end
    """

    sites =
      SourcePatch.assert_patches(
        source,
        [:integer, :tuple, :relational, :conditional],
        [{:run, [42]}, {:run, [43]}],
        call_routes: [{CustomKernel, :in, 2, [:expression, :raw]}]
      )

    refute Enum.any?(sites, &(&1.original_code in ["42", "{:limit, 42}", "n in {:limit, 42}"]))
  end

  test "Kernel mutators do not rename, strip, or transpose custom operators or calls" do
    families = [
      :arithmetic,
      :logical,
      :relational,
      :strict_equality,
      :conditional,
      :list,
      :operand_swap,
      :numeric,
      :call_removal
    ]

    for op <- [:!, :not, :abs, :and, :+, :==, :===, :++, :div, :min] do
      arity = if op in [:!, :not, :abs], do: 1, else: 2

      expression =
        cond do
          arity == 1 -> "#{op}({:ok, _})"
          op in [:div, :min] -> "#{op}({:ok, 42}, {:ok, _})"
          true -> "{:ok, 42} #{op} {:ok, _}"
        end

      positions = if arity == 1, do: [:pattern], else: [:expression, :pattern]
      source = source(op, arity, expression)

      {[module], sites} =
        compile_metamutant(source, families, call_routes: [{CustomKernel, op, arity, positions}])

      assert module.run() == true
      assert sites == [], "custom #{op}/#{arity}"
    end
  end

  test "a foreign inner operator keeps its route under Kernel negation" do
    for op <- [:!, :==, :===] do
      arity = if op == :!, do: 1, else: 2
      expression = if arity == 1, do: "!{:ok, 42}", else: "{:ok, 42} #{op} {:ok, 42}"
      positions = List.duplicate(:raw, arity)
      source = source(op, arity, "not (#{expression})")

      {[module], sites} =
        compile_metamutant(source, [:integer],
          call_routes: [{CustomKernel, op, arity, positions}]
        )

      assert module.run() == false
      assert Enum.all?(sites, &(&1.original_code == "123"))
    end
  end

  test "custom mutators can still replace a foreign Kernel-shaped call" do
    {[module], sites} =
      compile_metamutant(source(:!, 1, "!{:ok, _}"), [CustomNegationMutator],
        call_routes: [{CustomKernel, :!, 1, [:pattern]}]
      )

    assert {true, :changed} == observe_mutant(sites, {"!{:ok, _}", ":changed"}, &module.run/0)
  end

  test "custom standard-named sigils do not receive Kernel sigil mutations" do
    families = [:regex, :string_sigil, :charlist, :word_list, :datetime]

    for letter <- ~w(r s S c C w W D T N U) do
      sigil = String.to_atom("sigil_#{letter}")

      {[module], sites} =
        compile_metamutant(source(sigil, 2, "~#{letter}/#{sigil_payload(letter)}/"), families)

      assert module.run() == :valid
      assert sites == [], letter
    end
  end

  test "unresolved displaced calls do not receive Kernel-specific mutations" do
    source = """
    defmodule Target do
      import Kernel, except: [+: 2, div: 2, abs: 1, sigil_r: 2]
      import UnavailableOperators
      def run(a, b), do: {a + b, div(a, b), abs(a), ~r/valid/}
    end
    """

    assert diffs(source, [:arithmetic, :operand_swap, :call_removal, :regex]) == []
  end

  test "custom boolean-shaped calls remain eligible for condition and return mutants" do
    source = source(:==, 2, "{:ok, 42} == {:ok, 42}")
    opts = [call_routes: [{CustomKernel, :==, 2, :raw}]]
    sites = SourcePatch.assert_patches(source, [:return_value], [{:run, []}], opts)
    assert Enum.count(sites, &(&1.original_code == "{:ok, 42} == {:ok, 42}")) == 2

    source = source(:==, 2, "if {:ok, 42} == {:ok, 42}, do: :yes, else: :no")
    sites = SourcePatch.assert_patches(source, [:if_condition], [{:run, []}], opts)
    assert length(sites) == 2
  end

  test "custom string sigils are not assumed to return binaries" do
    source = """
    defmodule Target do
      import Kernel, except: [sigil_s: 2]
      import Mutare.Test.IntegerSigil
      def run, do: << ~s/valid/ >>
      def other, do: 123
    end
    """

    SourcePatch.assert_patches(source, [:integer], [{:run, []}, {:other, []}])
    {[module], _sites} = compile_metamutant(source, [:integer])
    assert module.run() == "A"
  end

  defp sigil_payload("D"), do: "2020-01-01"
  defp sigil_payload("T"), do: "12:00:00"
  defp sigil_payload("N"), do: "2020-01-01 12:00:00"
  defp sigil_payload("U"), do: "2020-01-01 12:00:00Z"
  defp sigil_payload(_), do: "valid"

  defp source(name, arity, expression) do
    """
    defmodule Target do
      import Kernel, except: [#{name}: #{arity}]
      import Mutare.Test.CustomKernel, only: [#{name}: #{arity}]
      def run, do: #{expression}
      def other, do: 123
    end
    """
  end
end
