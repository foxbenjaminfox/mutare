defmodule Mutare.Mutators.BitstringLiteral do
  @moduledoc """
  Bitstring-literal mutation: collapse a non-empty `<<…>>` literal to the empty
  bitstring `<<>>`. The binary sibling of `Mutare.Mutators.List`/`MapLiteral`/
  `TupleLiteral` — it asks "does anything depend on this binary's contents?". A
  binary that is built but whose bytes no test pins down lets `<<>>` survive.

  Only a genuine `<<…>>` literal is touched — not the other constructs that share
  the `{:<<>>, …}` AST shape:

    * an **interpolated string** (`"a\#{x}b"`) parses as a `<<>>` carrying a
      `delimiter` in its metadata. It is conceptually a string (in
      `StringLiteral`'s domain, which deliberately skips interpolations), so it is
      excluded here by that delimiter marker;
    * a **sigil's content** (`~r/…/`, `~D[…]`) is a `<<>>` *inside* the sigil node.
      `Mutare.Transform` does not descend into sigil internals (the sigil mutators
      own the whole node), so this never reaches here.

  In-place and compile-safe — `<<>>` is a legal value wherever a bitstring literal
  was. A bitstring in a *pattern* is routed to `:pattern` and not offered, so a
  match like `<<a, b>> = bin` is not corrupted. The segment *values* still mutate
  independently (a byte via `Literal`, a string segment via `StringLiteral`, an
  expression via `Arithmetic`, a `size(expr)` arg via `Literal`).
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :bitstring

  @impl Mutare.Mutator
  def mutate({:<<>>, meta, segments})
      when is_list(meta) and is_list(segments) and segments != [] do
    # A `delimiter` marks an interpolated string (a `<<>>` written as `"…"`), not a
    # `<<…>>` literal — leave it to StringLiteral's domain.
    if Keyword.has_key?(meta, :delimiter), do: :skip, else: [{:<<>>, [], []}]
  end

  def mutate(_node), do: :skip
end
