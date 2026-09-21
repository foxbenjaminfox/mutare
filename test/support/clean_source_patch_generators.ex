defmodule Mutare.Test.CleanSourcePatchGenerators do
  @moduledoc """
  Recursive companions to SourcePatchGenerators, targeting relocated clean copies.

  Every recursive step consumes a list tail; the enabled families only change arithmetic
  and comparisons, so even mutated programs terminate. A quoted payload contains calls
  with the recursive function's own name and arity, both as data and in executable escapes.
  The fixture records that payload's printed syntax and its recursive result. Printing is
  part of the fixture's behavior, not oracle normalization: wrapper-specific quote hygiene
  metadata is immaterial, but accidentally renamed calls remain observable.

  Quotes, live/disabled unquotes, nested quote options and quoted definitions compose with
  routed wrappers and direct/piped recursion. An unrelated function supplies real mutant
  IDs that select the recursive function's clean copy. Fixed cases cover every boundary
  with every routing mode; generated cases vary spelling, list contents and the initial
  accumulator. Runtime module creation and arbitrary recursion are deliberately excluded.
  """
  use PropCheck

  alias Mutare.Test.{SourcePatchFixtures, SourcePatchKeywordRoutes}

  def boundaries,
    do: [
      :quoted,
      :live,
      :spliced,
      :disabled,
      :bound,
      :nested_options,
      :nested_block_options,
      :definition
    ]

  def routings, do: [:ordinary, :interior, :raw, :skip, :keyed, :keyword]
  def spellings, do: [:direct, :piped]

  def recipe do
    let {boundary, routing, spelling, values, initial} <-
          {elements(boundaries()), elements(routings()), elements(spellings()),
           resize(3, list(integer(0, 4))), integer(-2, 2)} do
      %{
        boundary: boundary,
        routing: routing,
        spelling: spelling,
        values: values,
        initial: initial
      }
    end
  end

  def fixture(recipe) do
    base_call = call("[]", "n", recipe.spelling)
    {payload, opts} = recipe.boundary |> quoted(base_call) |> wrap(recipe.routing)
    recursion = call("rest", "acc + n", recipe.spelling)

    source = """
    defmodule RecursivePatchProgram do
      alias Mutare.Test.SourcePatchFixtures, as: F

      def run(values, initial), do: F.observe(fn -> walk(values, initial) end)

      def walk([], acc), do: acc
      def walk([n | rest], acc) when n >= 0 do
        payload = #{payload}
        F.tick(nil, {:payload, Macro.to_string(payload)})
        #{recursion}
      end

      def other(n), do: n < 1
    end
    """

    calls =
      Enum.uniq([
        {:run, [[], 0]},
        {:run, [[0], 1]},
        {:run, [[1, 2], 0]},
        {:run, [recipe.values, recipe.initial]},
        {:other, [-1]},
        {:other, [2]}
      ])

    %{source: source, calls: calls, mutators: [:arithmetic, :relational], opts: opts}
  end

  defp call(list, acc, :direct), do: "walk(#{list}, #{acc})"
  defp call(list, acc, :piped), do: "#{list} |> walk(#{acc})"

  defp quoted(:quoted, call), do: "quote(do: #{call})"
  defp quoted(:live, call), do: "quote(do: walk([], unquote(#{call})))"
  defp quoted(:spliced, call), do: "quote(do: [walk([], n), unquote_splicing([#{call}])])"
  defp quoted(:disabled, call), do: "quote(unquote: false, do: unquote(#{call}))"
  defp quoted(:bound, call), do: "quote(bind_quoted: [value: #{call}], do: walk([], value))"

  defp quoted(:nested_options, call),
    do: "quote(do: quote(bind_quoted: [value: unquote(#{call})], do: walk([], value)))"

  # Options and block as two arguments: Elixir quotes these options with escapes still on,
  # so this recursion runs, where the one-list `:nested_options` above is data throughout.
  defp quoted(:nested_block_options, call),
    do: "quote(do: quote([bind_quoted: [value: unquote(#{call})]], do: walk([], value)))"

  defp quoted(:definition, call),
    do: "quote(do: def(walk(xs, acc), do: walk(xs, unquote(#{call}))))"

  defp wrap(payload, :ordinary), do: {"F.identity(#{payload})", []}

  defp wrap(payload, routing) when routing in [:interior, :raw, :skip],
    do: {"F.identity(#{payload})", [call_routes: [{SourcePatchFixtures, :identity, 1, routing}]]}

  defp wrap(payload, :keyed),
    do:
      {"Keyword.get([value: #{payload}], :value)",
       [call_routes: [{Keyword, :get, 2, [[:expression, value: :expression], :expression]}]]}

  defp wrap(payload, :keyword),
    do: {"Keyword.get([value: #{payload}], :value)", [extensions: [SourcePatchKeywordRoutes]]}
end
