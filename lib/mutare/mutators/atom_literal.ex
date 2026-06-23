defmodule Mutare.Mutators.AtomLiteral do
  @moduledoc """
  Atom-literal mutations: replace a literal atom with a distinct sentinel atom
  (`:mutare`), dropping the replacement when the original already equals it.

  So `:waiting` → `:mutare` (one mutant); `:mutare` itself yields none. The sentinel
  is the atom counterpart of `Mutare.Mutators.StringLiteral`'s non-empty `"mutare"`
  arm — a guaranteed-distinct value that a real assertion (`status == :waiting`, a
  message atom) pins down but a too-weak suite does not. Unlike a string there is no
  "empty" atom, so a single sentinel is the whole family.

  ## What is *not* mutated

    * **`true` / `false` / `nil`** — these parse as atom literals too, but booleans
      belong to `Mutare.Mutators.Literal` (and `Conditional`), and `nil` is the absence
      sentinel.
    * **Convention atoms** (`:ok`/`:error`, `:cont`/`:halt`, `:lt`/`:gt`) — owned by
      `Mutare.Mutators.ConventionAtom`, which swaps each for its high-signal same-shape
      *sibling* (`:ok` → `:error`) rather than the sentinel.
    * **Block keys** (`do:`/`else:`/`rescue:`/`catch:`/`after:`), a `%Struct{field: v}`
      field name, and a `for` option (`into:`/`uniq:`/`reduce:`) — mutating these would
      be illegal or a compile error.

  Ordinary atoms in data keyword/map keys (`%{a: :b}`, `[a: :b]`) and in
  `case`/`receive`/`fn` clause patterns **are** mutated. The key of a keyword passed as
  a call's trailing argument (`foo(timeout: 5)`) is mutated too — opt out per mutator
  with `{Mutare.Mutators.AtomLiteral, call_option_keys: false}`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @sentinel AST.sentinel_atom()

  # Convention atoms (`:ok`/`:error`, …) are owned by `Mutare.Mutators.ConventionAtom`,
  # which swaps each for its high-signal same-shape sibling rather than the sentinel — so
  # they are excluded here, the way `true`/`false`/`nil` are deferred to `Literal`/
  # `Conditional`. Single source of truth: the list lives with that family (the
  # `@sentinel AST.sentinel_atom()` pattern). As with the boolean/nil split, disabling
  # `:convention` leaves these atoms unmutated by `:atom` too.
  @convention Mutare.Mutators.ConventionAtom.members()

  @impl Mutare.Mutator
  def name, do: :atom

  @impl Mutare.Mutator
  # `true`/`false`/`nil` are atom literals but belong elsewhere (see @moduledoc).
  def mutate({:__block__, _meta, [a]}) when is_boolean(a) or is_nil(a), do: :skip

  # A convention atom is owned by `ConventionAtom` (see @moduledoc).
  def mutate({:__block__, _meta, [a]}) when a in @convention, do: :skip

  # Any other literal atom → the sentinel, unless it already is the sentinel.
  def mutate({:__block__, _meta, [a]}) when is_atom(a) and a != @sentinel,
    do: [AST.literal(@sentinel)]

  def mutate(_node), do: :skip
end
