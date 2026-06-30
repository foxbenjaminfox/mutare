defmodule Mutare.Mutators.AtomLiteral do
  @moduledoc """
  Replaces a literal atom with `:mutare`. The replacement is omitted when the
  original atom is already `:mutare`.

  The following atoms are excluded:

    * `true`, `false`, and `nil`, which are handled by literal and conditional
      families
    * `:ok`/`:error`, `:cont`/`:halt`, and `:lt`/`:gt`, which are handled by
      `Mutare.Mutators.ConventionAtom`
    * block keys such as `do:`, `else:`, and `rescue:`
    * struct field names and `for` options such as `into:`, `uniq:`, and `reduce:`

  Ordinary atom values, data map and keyword keys, and atoms in `case`, `receive`,
  and `fn` patterns remain eligible. Keys in a trailing call-options list are also
  mutated by default. Configure
  `{Mutare.Mutators.AtomLiteral, call_option_keys: false}` to exclude those keys.
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
  def mutate_call_option_keys?(opts) do
    not (Keyword.keyword?(opts) and Keyword.get(opts, :call_option_keys, true) == false)
  end

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
