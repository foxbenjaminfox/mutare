defmodule Mutare.Test.SourcePatchGenerators do
  @moduledoc """
  Bounded, shrinkable source programs for the per-mutant semantic property.

  The case is a small recipe, not an arbitrary AST: shrinking preserves bound variables,
  valid routes and compilable patches. It crosses operand scope/routing, call spelling,
  callee evaluation and selector delivery. An optional identity wrapper adds nesting.
  Values vary independently; the fixed input rows include zero divisors and lazy branches.

  Every fixture has a mutation-bearing `other/1`. SourcePatch probes both functions under
  every mutant, exercising the clean path when a mutant belongs elsewhere as well as the
  baseline and active path. Relational mutations also exercise lifted guard delivery.

  This deliberately small vocabulary complements the broad transform AST generator. It
  does not generate arbitrary recursion, nested definitions or hosted DSLs. Adding a
  construct means declaring its escaping names, then including it in `operands/0` so the
  deterministic cross-product exercises it too. No failed compile is discarded.
  """
  use PropCheck

  alias Mutare.Test.{SourcePatchDynamicMutator, SourcePatchFixtures, SourcePatchKeywordRoutes}

  def operands, do: [:plain, :binding, :skipped, :raw, :keyed, :keyword, :unquote, :quoted, :lazy]
  def spellings, do: [:direct, :piped, :grouped]
  def deliveries, do: [:retained, :moved, :split]
  def callees, do: [:static, :dynamic]

  def recipe do
    let {operand, spelling, delivery, callee, wrapped?, offset} <-
          {elements(operands()), elements(spellings()), elements(deliveries()),
           elements(callees()), boolean(), integer(-3, 3)} do
      %{
        operand: operand,
        spelling: spelling,
        delivery: delivery,
        callee: callee,
        wrapped?: wrapped?,
        offset: offset
      }
    end
  end

  def fixture(recipe) do
    {left, bindings, opts} = operand(recipe.operand)
    left = if recipe.wrapped?, do: "F.identity(#{left})", else: left
    right = "(right = F.tick(divisor, :right))"
    callee = if recipe.callee == :static, do: "div", else: "F.receiver().div"

    expression =
      case recipe.spelling do
        :direct -> "abs(#{callee}(#{left}, #{right}))"
        :piped -> "#{left} |> #{callee}(#{right}) |> abs()"
        :grouped -> "#{left} |> (#{callee}(#{right}) |> abs())"
      end

    source = """
    defmodule PatchProgram do
      alias Mutare.Test.SourcePatchFixtures, as: F
      require F

      def run(n, divisor, enabled) when n <= 20 do
        F.observe(fn ->
          result = #{expression}
          {result, #{Enum.join(bindings ++ ["right"], ", ")}}
        end)
      end

      def other(n), do: n < 1
    end
    """

    # None of these mutations deletes a binding. Arithmetic failures are valid observable
    # outcomes; invalid generated source or source patches are test failures.
    mutators =
      case {recipe.callee, recipe.delivery} do
        {:static, :retained} -> [:arithmetic]
        {:static, :moved} -> [:operand_swap]
        {:static, :split} -> [:arithmetic, :operand_swap]
        {:dynamic, delivery} -> [{SourcePatchDynamicMutator, delivery: delivery}]
      end

    calls =
      for {n, divisor, enabled} <- [{8, 3, true}, {-7, 2, false}, {0, 0, true}],
          do: {:run, [n + recipe.offset, divisor, enabled]}

    %{
      source: source,
      mutators: mutators ++ [:relational],
      calls: calls ++ [other: [-1], other: [2]],
      opts: opts
    }
  end

  defp operand(:plain), do: {"F.tick(n, :left)", [], []}
  defp operand(:binding), do: {"(left = F.tick(n, :left))", ["left"], []}

  defp operand(:skipped),
    do:
      {"F.identity(left = F.tick(n, :left))", ["left"],
       [call_routes: [{SourcePatchFixtures, :identity, 1, :skip}]]}

  defp operand(:raw),
    do:
      {"F.raw(div(F.tick(n, :left), 2))", [],
       [call_routes: [{SourcePatchFixtures, :raw, 1, :raw}]]}

  defp operand(:keyed),
    do:
      {"Keyword.get([value: left = F.tick(n, :left)], :value)", ["left"],
       [call_routes: [{Keyword, :get, 2, [[:expression, value: :expression], :expression]}]]}

  defp operand(:keyword),
    do:
      {"Keyword.get([value: left = F.tick(n, :left)], :value)", ["left"],
       [extensions: [SourcePatchKeywordRoutes]]}

  defp operand(:unquote),
    do: {"hd(quote(do: [unquote(left = F.tick(n, :left))]))", ["left"], []}

  defp operand(:quoted),
    do: {"length(quote(do: [hidden = 4, quote(do: unquote(hidden = 9))]))", [], []}

  defp operand(:lazy),
    do:
      {"F.lazy(F.tick(n, :left), enabled)", [],
       [call_routes: [{SourcePatchFixtures, :lazy, 2, [:lazy_expression, :expression]}]]}
end
