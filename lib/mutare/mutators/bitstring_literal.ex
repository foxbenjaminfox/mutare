defmodule Mutare.Mutators.BitstringLiteral do
  @moduledoc """
  Bitstring-literal mutation: collapse a non-empty `<<…>>` literal to the empty bitstring `<<>>`. The binary sibling of `Mutare.Mutators.List`/`MapLiteral`/ `TupleLiteral` — it asks "does anything depend on this binary's contents?". A binary that is built but whose bytes no test pins down lets `<<>>` survive.

  Not mutated — constructs that merely share the `<<…>>` AST shape:

    * an interpolated string (`"a\#{x}b"`) — conceptually a string, left to `StringLiteral`'s domain (which mutates the whole interpolated string to `""`/`"mutare"`, the empty-bitstring collapse being the wrong shape for it);
    * a sigil's content (`~r/…/`, `~D[…]`) — the sigil mutators own the whole node;
    * an interpolated quoted atom's content (the `<<>>` inside `:"a\#{x}b"`'s `binary_to_atom` call) — atom content, owned whole by `AtomLiteral`; the analyzer never offers the wrapper here.

  A bitstring in a *pattern* is left alone, so a match like `<<a, b>> = bin` is not corrupted. The segment *values* still mutate independently (a byte via `Literal`, a string segment via `StringLiteral`, an expression via `Arithmetic`, a `size(expr)` arg via `Literal`).
  """
  @behaviour Mutare.Mutator
  use Mutare.Mutator.SkipArguments

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :bitstring

  @impl Mutare.Mutator
  def mutate({:<<>>, meta, segments} = node)
      when is_list(meta) and is_list(segments) and segments != [] do
    # A `delimiter` marks an interpolated string (a `<<>>` written as `"…"`), not a
    # `<<…>>` literal — leave it to StringLiteral's domain.
    if AST.string_binary?(node), do: :skip, else: [{:<<>>, [], []}]
  end

  def mutate(_node), do: :skip
end
