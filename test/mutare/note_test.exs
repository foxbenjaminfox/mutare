defmodule Mutare.NoteTest do
  @moduledoc """
  The per-mutant **note** channel on the standard `c:Mutare.Mutator.mutate/1`/`c:Mutare.Mutator.mutate/2`
  API — generalized from the selector host so *any* node-level mutator can attach an advisory the
  report surfaces on a survivor.

  A `mutate` return-list element is one of `t:Mutare.Mutator.mutation/0`: a bare node (no note) or a
  `%Mutare.Mutator.Mutation{}` (a node + a note). A top-level bare `nil` list item is rejected
  instead of being a drop sentinel; literal nil is expressed as `Mutare.AST.literal(nil)`. Proven
  across the three positions a `mutate` result lands — an in-place body literal, a lifted `def`-head
  literal, and a `case`-clause literal — with `Mutare.Test.NotedMutator`.
  """
  use ExUnit.Case, async: true

  alias Mutare.Mutator.Dispatch
  alias Mutare.Mutator.Mutation

  defmodule BareNilMutator do
    @moduledoc false
    @behaviour Mutare.Mutator

    @impl Mutare.Mutator
    def name, do: :bare_nil

    @impl Mutare.Mutator
    def mutate(_node), do: [nil]
  end

  @source """
  defmodule Mutare.NoteFixture do
    def body, do: 42

    def head(42), do: :ok
    def head(_), do: :no

    def in_case(x) do
      case x do
        42 -> :ok
        _ -> :no
      end
    end
  end
  """

  setup_all do
    %{sites: sites} =
      Mutare.Transform.transform_string_with_sites(@source,
        file: "note.ex",
        mutators: [Mutare.Test.NotedMutator]
      )

    %{sites: sites}
  end

  defp noted_site(sites, line),
    do: Enum.find(sites, &(&1.mutated_code == "0" and &1.line == line))

  defp bare_site(sites, line),
    do: Enum.find(sites, &(&1.mutated_code == "1" and &1.line == line))

  defp nil_site(sites, line),
    do: Enum.find(sites, &(&1.mutated_code == "nil" and &1.line == line))

  describe "the note channel across positions" do
    test "each mutated 42 yields a noted 0, literal nil, and a bare 1", %{sites: sites} do
      # Three positions (body, head, case clause) × {0, nil, 1} = 9 `:noted` sites. (The always-on
      # `clause_drop` also fires on the two-clause `head/1`, so we filter to this mutator's own
      # sites.)
      noted = Enum.filter(sites, &(&1.mutator == :noted))
      assert length(noted) == 9
      assert Enum.count(noted, &(&1.mutated_code == "0")) == 3
      assert Enum.count(noted, &(&1.mutated_code == "nil")) == 3
      assert Enum.count(noted, &(&1.mutated_code == "1")) == 3
    end

    test "the note rides onto the noted Site; unnoted mutants have none", %{sites: sites} do
      for line <- [2, 4, 9] do
        assert noted_site(sites, line).note == "off-by-one suspected"
        assert nil_site(sites, line).note == nil
        assert bare_site(sites, line).note == nil
      end
    end

    test "in-place body, lifted head, and case-clause positions all carry it", %{sites: sites} do
      # def body, do: 42  → in-place body selector
      assert noted_site(sites, 2).kind == :in_place
      # def head(42)      → lifted (a case is illegal in a head pattern)
      assert noted_site(sites, 4).kind == :lifted
      # case … 42 -> …    → tuple-the-scrutinee, delivered in place
      assert noted_site(sites, 9).kind == :in_place
    end

    test "the survivor header appends the note; a bare mutant's does not", %{sites: sites} do
      assert Mutare.Report.header(noted_site(sites, 2)) =~ "SURVIVED  — off-by-one suspected"
      assert Mutare.Report.header(bare_site(sites, 2)) =~ ~r/SURVIVED$/
    end

    test "the metamutant compiles" do
      Mutare.Test.assert_metamutant_compiles(@source, [Mutare.Test.NotedMutator])
    end
  end

  describe "Mutation.new/tagged and to_result/2 (the shared noted-mutant contract)" do
    alias Mutare.Mutator.Dispatch.Result

    @arith Mutare.Mutator.Spec.for_module(Mutare.Mutators.Arithmetic)

    test "new/2 builds the struct; new/1 defaults the note to nil" do
      assert Mutation.new(1, "why") == %Mutation{node: 1, note: "why"}
      assert Mutation.new(1) == %Mutation{node: 1, note: nil}
    end

    test "new/2 rejects a non-string positional note at the guard" do
      assert_raise FunctionClauseError, fn -> Mutation.new(1, 42) end
    end

    test "new/2 takes a keyword list to carry note and/or variant together" do
      assert Mutation.new(1, note: "why", variant: "zero") ==
               %Mutation{node: 1, note: "why", variant: "zero"}

      # Either key is optional; absent ones default to nil (an empty list = no metadata).
      assert Mutation.new(1, variant: "zero") == %Mutation{node: 1, note: nil, variant: "zero"}
      assert Mutation.new(1, note: "why") == %Mutation{node: 1, note: "why", variant: nil}
      assert Mutation.new(1, []) == %Mutation{node: 1, note: nil, variant: nil}

      # A list of labels rides through unchanged (normalized downstream, like variant/2's return).
      assert Mutation.new(1, variant: ["pred", "zero"]).variant == ["pred", "zero"]
    end

    test "new/2 keyword form is the same value as tagged/2 for a variant-only mutant" do
      assert Mutation.new(1, variant: "zero") == Mutation.tagged(1, "zero")
    end

    test "new/2 rejects an unknown keyword key (a typo fails loud, not silently dropped)" do
      assert_raise ArgumentError, ~r/unknown keys \[:varient\]/, fn ->
        Mutation.new(1, varient: "zero")
      end
    end

    test "new/2 rejects a non-string note given via the keyword form" do
      assert_raise ArgumentError, ~r/:note must be a string or nil/, fn ->
        Mutation.new(1, note: 42)
      end
    end

    test "to_result records a struct / bare node with its note and variant under the spec" do
      assert Dispatch.to_result(%Mutation{node: {:x, [], nil}, note: "n"}, @arith) ==
               %Result{spec: @arith, node: {:x, [], nil}, note: "n"}

      assert Dispatch.to_result({:x, [], nil}, @arith) == %Result{
               spec: @arith,
               node: {:x, [], nil}
             }
    end

    test "tagged/2 carries the variant label(s) through to_result" do
      assert Mutation.tagged(1, "zero") == %Mutation{node: 1, note: nil, variant: "zero"}

      assert Dispatch.to_result(%Mutation{node: {:x, [], nil}, variant: "zero"}, @arith) ==
               %Result{spec: @arith, node: {:x, [], nil}, variant: "zero"}

      assert Dispatch.to_result(%Mutation{node: 1, note: "n", variant: ["pred", "zero"]}, @arith) ==
               %Result{spec: @arith, node: 1, note: "n", variant: ["pred", "zero"]}
    end

    test "a producer spec becomes the recording spec; a non-spec producer is rejected" do
      producer = Mutare.Mutator.Spec.for_module(Mutare.Mutators.IntegerLiteral)

      assert Dispatch.to_result(%Mutation{node: 1, producer: producer}, @arith) ==
               %Result{spec: producer, node: 1}

      assert_raise ArgumentError, ~r/:producer must be a Mutare.Mutator.Spec or nil/, fn ->
        Dispatch.to_result(
          %Mutation{node: 1, producer: Mutare.Mutators.IntegerLiteral},
          @arith
        )
      end

      assert_raise ArgumentError, ~r/:producer must be a Mutare.Mutator.Spec or nil/, fn ->
        Mutation.new(1, producer: :integer)
      end
    end

    test "a bare %{node:, note:} map is rejected (the struct is required)" do
      assert_raise ArgumentError,
                   ~r/must be a %Mutare.Mutator.Mutation\{\}, not a bare map/,
                   fn ->
                     Dispatch.to_result(%{node: 1, note: "n"}, @arith)
                   end
    end

    test "a non-string struct note is rejected" do
      assert_raise ArgumentError, ~r/:note must be a string or nil/, fn ->
        Dispatch.to_result(%Mutation{node: 1, note: 42}, @arith)
      end
    end

    test "a foreign struct (not a Mutation) is rejected, not silently treated as a node" do
      # No quoted AST node is a struct, so any struct other than %Mutation{} is a library bug —
      # fail loud rather than letting it through as `mutated` (which would crash Sourceror later).
      assert_raise ArgumentError, ~r/must be a %Mutare.Mutator.Mutation\{\}, got a/, fn ->
        Dispatch.to_result(1..2, @arith)
      end
    end

    test "an empty-string note is coerced to nil (a blank note carries no signal)" do
      # So the report never renders a dangling "  — " suffix; the same coercion the header
      # already proves it produces no em-dash for a noteless mutant (see above).
      assert Dispatch.to_result(%Mutation{node: 1, note: ""}, @arith) == %Result{
               spec: @arith,
               node: 1
             }
    end

    test "a bare nil mutation item raises instead of disappearing" do
      assert_raise ArgumentError,
                   ~r/cannot be bare nil.*filter.*Mutare\.AST\.literal\(nil\)/s,
                   fn ->
                     Dispatch.mutations({:__block__, [], [42]}, [BareNilMutator])
                   end
    end
  end
end
