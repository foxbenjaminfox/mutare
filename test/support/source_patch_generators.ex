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
  does not generate arbitrary recursion or nested definitions. Adding a construct means
  declaring its escaping names, then including it in `operands/0`: `pairwise/0` then
  exercises it against every value of every other dimension. No failed compile is discarded.

  `pairwise/0` is a covering array, not a cross-product: every pair of values from two
  different dimensions appears in at least one recipe. The failures this vocabulary was
  built from were each an interaction of two features, and a chosen pair of dimensions
  leaves the others to chance.
  """
  use PropCheck

  alias Mutare.Test.{HostMutator, SourcePatchDynamicMutator, SourcePatchFixtures}
  alias Mutare.Test.{SourcePatchKeywordRoutes, SourcePatchUnwrapMutator}

  def operands,
    do: [
      :plain,
      :binding,
      :block,
      :skipped,
      :raw,
      :keyed,
      :keyword,
      :unquote,
      :quoted,
      :lazy,
      :hosted
    ]

  def spellings, do: [:direct, :piped, :grouped]
  def deliveries, do: [:retained, :moved, :split]

  # `:binding` is a dynamic callee whose receiver expression itself binds a name read later.
  def callees, do: [:static, :dynamic, :binding]

  def dimensions,
    do: [
      operand: operands(),
      spelling: spellings(),
      delivery: deliveries(),
      callee: callees(),
      wrapped?: [false, true]
    ]

  @doc "Recipes that together contain every pair of values from two different dimensions."
  def pairwise do
    dimensions = dimensions()

    candidates =
      Enum.reduce(dimensions, [%{offset: 0}], fn {dimension, values}, recipes ->
        for recipe <- recipes, value <- values, do: Map.put(recipe, dimension, value)
      end)

    cover(candidates, MapSet.new(Enum.flat_map(candidates, &pairs/1)), [])
  end

  @doc "The cross-dimension value pairs one recipe contains."
  def pairs(recipe) do
    entries =
      for {dimension, _values} <- dimensions(), do: {dimension, Map.fetch!(recipe, dimension)}

    for {left, i} <- Enum.with_index(entries),
        right <- Enum.drop(entries, i + 1),
        do: {left, right}
  end

  # Greedy: take the recipe covering the most still-uncovered pairs. Deterministic, since
  # `Enum.max_by/2` keeps the first of equals and the candidates are in a fixed order.
  defp cover(candidates, uncovered, chosen) do
    if MapSet.size(uncovered) == 0 do
      Enum.reverse(chosen)
    else
      best =
        Enum.max_by(candidates, fn recipe -> Enum.count(pairs(recipe), &(&1 in uncovered)) end)

      cover(candidates, MapSet.difference(uncovered, MapSet.new(pairs(best))), [best | chosen])
    end
  end

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

    {callee, callee_bindings} =
      case recipe.callee do
        :static -> {"div", []}
        :dynamic -> {"F.receiver().div", []}
        :binding -> {"(receiver = F.receiver()).div", ["receiver"]}
      end

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
      import Mutare.Test.HostDSL, only: [filter: 2]

      def run(n, divisor, enabled) when n <= 20 do
        F.observe(fn ->
          result = #{expression}
          {result, #{Enum.join(bindings ++ callee_bindings ++ ["right"], ", ")}}
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
        {_dynamic, delivery} -> [{SourcePatchDynamicMutator, delivery: delivery}]
      end

    extra =
      case recipe.operand do
        :hosted -> [HostMutator]
        :block -> [SourcePatchUnwrapMutator]
        _other -> []
      end

    calls =
      for {n, divisor, enabled} <- [{8, 3, true}, {-7, 2, false}, {0, 0, true}],
          do: {:run, [n + recipe.offset, divisor, enabled]}

    %{
      source: source,
      mutators: mutators ++ extra ++ [:relational],
      calls: calls ++ [other: [-1], other: [2]],
      opts: opts
    }
  end

  defp operand(:plain), do: {"F.tick(n, :left)", [], []}
  defp operand(:binding), do: {"(left = F.tick(n, :left))", ["left"], []}

  # A statement sequence, whose parentheses are the negation's: the mutant that removes the
  # negation (`SourcePatchUnwrapMutator`) has to restore them in its replacement text.
  defp operand(:block),
    do: {"-(left = F.tick(n, :left); left)", ["left"], []}

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

  # A fragment core mutates inside a DSL: the host weaves its selector into `divisor > 1`,
  # and the macro evaluates that condition before its query.
  defp operand(:hosted),
    do: {"List.first(filter([F.tick(n, :left)], F.tick(divisor, :condition) > 1), 0)", [], []}

  defp operand(:lazy),
    do:
      {"F.lazy(F.tick(n, :left), enabled)", [],
       [call_routes: [{SourcePatchFixtures, :lazy, 2, [:lazy_expression, :expression]}]]}
end
