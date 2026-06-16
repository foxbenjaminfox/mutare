defmodule Mutare.Mutators.RegexLiteral do
  @moduledoc """
  Regex-sigil mutations: replace a `~r/…/` pattern with both the empty pattern
  `~r//` and a sentinel (`~r/mutare/`), dropping whichever already equals the
  original. The modifier flags (`~r/…/i`) are preserved.

  A contrasting pair, like `Mutare.Mutators.StringLiteral`: `~r//` matches at
  every position (so `Regex.match?/2` is always true), while `~r/mutare/` matches
  essentially no real input (always false). Between them they catch a suite that
  never exercises what the pattern actually accepts or rejects.

  In-place and compile-safe — both replacements are valid regexes legal wherever
  the original was. Only non-interpolated patterns are touched: an interpolated
  `~r/\#{x}/` parses with multiple `<<>>` parts (not a single binary), so the
  pattern operand is always static.
  """
  @behaviour Mutare.Mutator

  @sentinel "mutare"

  @impl Mutare.Mutator
  def name, do: :regex

  @impl Mutare.Mutator
  def mutate({:sigil_r, meta, [{:<<>>, bmeta, [pattern]}, modifiers]}) when is_binary(pattern) do
    ["", @sentinel]
    |> Enum.reject(&(&1 == pattern))
    |> Enum.map(&{:sigil_r, meta, [{:<<>>, bmeta, [&1]}, modifiers]})
  end

  def mutate(_node), do: :skip
end
