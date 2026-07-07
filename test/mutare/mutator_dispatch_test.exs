defmodule Mutare.MutatorDispatchTest do
  use ExUnit.Case, async: true

  alias Mutare.Mutator.Dispatch
  alias Mutare.Mutator.Spec

  defmodule OneArityOnly do
    @behaviour Mutare.Mutator

    @impl true
    def name, do: :one_arity_only

    @impl true
    def mutate({:__block__, _meta, [1]}), do: [Mutare.AST.literal(:one)]
    def mutate(_node), do: :skip
  end

  defmodule TwoArityOnly do
    @behaviour Mutare.Mutator

    @impl true
    def name, do: :two_arity_only

    @impl true
    def mutate({:__block__, _meta, [1]}, %{opts: opts}) do
      [Mutare.AST.literal(Keyword.fetch!(opts, :replacement))]
    end

    def mutate(_node, _context), do: :skip
  end

  defmodule BothArities do
    @behaviour Mutare.Mutator

    @impl true
    def name, do: :both_arities

    @impl true
    def mutate({:__block__, _meta, [1]}), do: [Mutare.AST.literal(:one)]
    def mutate(_node), do: :skip

    @impl true
    def mutate({:__block__, _meta, [1]}, _context), do: [Mutare.AST.literal(:two)]
    def mutate(_node, _context), do: :skip
  end

  describe "mutations/3 callback precedence" do
    test "falls back to mutate/1 when mutate/2 is absent" do
      assert rendered_mutations(OneArityOnly) == [":one"]
    end

    test "runs mutate/2 when present and passes spec options" do
      assert rendered_mutations(Spec.configured(TwoArityOnly, replacement: :configured)) ==
               [":configured"]
    end

    test "prefers mutate/2 over mutate/1 when both are exported" do
      assert rendered_mutations(BothArities) == [":two"]
    end
  end

  defp rendered_mutations(entry) do
    node = Mutare.AST.parse!("1")

    for %Dispatch.Result{node: mutated} <- Dispatch.mutations(node, [entry]),
        do: Mutare.AST.to_string(mutated)
  end
end
