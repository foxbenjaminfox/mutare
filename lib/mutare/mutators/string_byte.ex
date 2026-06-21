defmodule Mutare.Mutators.StringByte do
  @moduledoc """
  Narrow the **grapheme-aware `String.length` to the byte-level `byte_size`** — the
  question "does this code actually depend on Unicode/grapheme semantics, or would
  raw byte semantics pass the suite?":

    * `String.length(s)` → `Elixir.Kernel.byte_size(s)`   — grapheme **count** → byte **count**

  For pure-ASCII input the two return the *same* number, so a suite that only ever
  exercises ASCII can't tell them apart — exactly the gap this surfaces. The moment a
  multi-byte grapheme is involved (`"héllo"` is 5 graphemes but 6 bytes) the answers
  diverge, so a surviving mutant pinpoints code whose UTF-8 length handling is
  untested. Crucially the swap is **type-preserving** — both return a non-negative
  integer — so it probes a real semantic gap rather than trivially crashing on a type
  mismatch.

  ## One-way on purpose

  The swap is deliberately **one-directional** (`String.length` → `byte_size`), never
  the reverse, because `byte_size` is strictly more general and the reverse would be
  unsound or noisy: `byte_size/1` is a `Kernel` **guard** that accepts *any* binary or
  bitstring, whereas `String.length/1` is illegal in a guard (so the reverse would
  poison every `when byte_size(x) …`) and raises on a bitstring or invalid UTF-8. It is
  also ubiquitous on non-string binaries, where "graphemes" is meaningless — the reverse
  would fire all over byte-manipulation code that has nothing to do with text. Narrowing
  the specific string-aware call to the general byte op is the honest mutation;
  broadening a byte op to a string op is not. So this family has no swap table — just the
  one forward rewrite.

  ## Why `Elixir.Kernel.byte_size`, not bare `byte_size`

  The mutant qualifies the target with the **absolute** `Elixir.Kernel` alias rather
  than emitting a bare `byte_size(s)`. The qualification is spelled to resolve
  *independently of the target module's lexical environment*, so the generated call
  always means the real builtin:

    * a **bare** `byte_size(s)` would resolve to a same-named local definition or
      selective import if one shadowed the name (`import Kernel, except: [byte_size: 1]`
      plus a local `def byte_size/1`), silently changing what the mutant means;
    * a plainly-qualified `Kernel.byte_size` survives that, but a later
      `alias Foo, as: Kernel` would redirect it — so the qualifier is the **absolute**
      `Elixir.Kernel` (`__aliases__` led by `:Elixir`, which alias resolution never
      rewrites), the same alias-proof form `Mutare.Transform` uses for its generated
      `Elixir.Kernel.raise` / `Elixir.MatchError` nodes.

  (`String.length` is never legal in a guard, so the qualified remote target needs no
  guard-safety consideration.)

  ## Resolution and pipes

  The `String.length` source is recognised by its **resolved** module through the shared
  `Mutare.Transform.Calls` reader, so the direct, aliased, and bare-imported forms all
  match: `String.length(s)`, `alias String, as: S; S.length(s)`, and
  `import String; length(s)` — while a shadowing `alias MyApp.String` resolves to the
  local module and is correctly left alone. The swap is a one-to-one rename onto a fixed
  target arity (`String.length/1` → `Elixir.Kernel.byte_size/1`) that reuses the source's
  argument list verbatim, so it stays correct in a pipe with no pipe context needed
  (`s |> String.length()` → `s |> Elixir.Kernel.byte_size()`). The target is built
  directly rather than through `Calls`' `rebuild`, since the swap deliberately *changes
  module*.

  On by default. The byte-semantics sibling of `Mutare.Mutators.StringCall` (which swaps
  a `String` call for its same-module directional opposite); here the swap crosses out of
  `String` into the byte world.
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
