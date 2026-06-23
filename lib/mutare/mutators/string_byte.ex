defmodule Mutare.Mutators.StringByte do
  @moduledoc """
  Narrow the **grapheme-aware `String.length` to the byte-level `byte_size`** — the
  question "does this code actually depend on Unicode/grapheme semantics, or would
  raw byte semantics pass the suite?":

    * `String.length(s)` → `byte_size(s)`   — grapheme **count** → byte **count**

  For pure-ASCII input the two return the *same* number, so a suite that only ever
  exercises ASCII can't tell them apart — exactly the gap this surfaces. The moment a
  multi-byte grapheme is involved (`"héllo"` is 5 graphemes but 6 bytes) the answers
  diverge, so a surviving mutant pinpoints code whose UTF-8 length handling is
  untested. The swap is **type-preserving** — both return a non-negative integer.

  The swap is deliberately **one-directional** (`String.length` → `byte_size`), never
  the reverse: `byte_size` is strictly more general (it accepts any binary and is legal
  in a guard, where `String.length` is not), so broadening a byte op to a string op
  would be unsound or noisy. So this family has just the one forward rewrite.

  On by default. Matches aliased and bare-imported `String.length` too, while a
  shadowing `alias MyApp.String` is left alone. The byte-semantics sibling of
  `Mutare.Mutators.StringCall` — there the swap stays within `String`; here it crosses
  out of `String` into the byte world.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Calls

  @impl Mutare.Mutator
  def name, do: :string_byte

  @impl Mutare.Mutator
  def mutate(node) do
    case Calls.resolved_call(node) do
      # `String.length(s)` (grapheme count) → `Elixir.Kernel.byte_size(s)` (byte count).
      # Absolute-qualified so neither a local/selective-import `byte_size` nor a later
      # `alias Foo, as: Kernel` can shadow it; built directly (not via `rebuild`) since it
      # crosses module out of `String`.
      {[:String], :length, args, _rebuild} -> [byte_size_call(args)]
      _ -> :skip
    end
  end

  defp byte_size_call(args) do
    {{:., [], [{:__aliases__, [], [:"Elixir", :Kernel]}, :byte_size]}, [], args}
  end
end
