defmodule Mutare.Mutators.AtomLiteral do
  @moduledoc """
  Replaces a literal atom with `:mutare`. The replacement is omitted when the original atom is already `:mutare`.

  The following atoms are excluded:

    * `true` and `false`, handled by `Mutare.Mutators.BooleanLiteral`; and `nil`, left unmutated
    * `:ok`/`:error`, `:cont`/`:halt`, and `:lt`/`:gt`, which are handled by `Mutare.Mutators.ConventionAtom`
    * block keys such as `do:`, `else:`, and `rescue:`
    * struct field names and `for` options such as `into:`, `uniq:`, and `reduce:`

  Ordinary atom values, data map and keyword keys, and atoms in `case`, `receive`, and `fn` patterns remain eligible. Keys in a trailing call-options list are also mutated by default. Configure `{Mutare.Mutators.AtomLiteral, call_option_keys: false}` to exclude those keys.

  `:infinity` in a known **timeout/duration position** (e.g. the `Task.await/2` or `GenServer.stop/3` timeout) is left unmutated. This family reuses `Mutare.Mutators.IntegerLiteral`'s timeout table (via `c:Mutare.Mutator.argument_marks/1`) so the two value families agree on which positions hold an opaque timeout literal, and declines when the `:timeout` mark is present. A *non-duration* sibling atom in the same call still mutates: `GenServer.stop(s, :normal, :infinity)` mutates the `:normal` reason but not the `:infinity` timeout.

  Project-specific timeout positions come from the `argument_marks:` option (declared with the
  `:timeout` label, as documented on `Mutare.Mutators.IntegerLiteral`); `:infinity` at such a
  position is left alone the same way. To keep an atom position out of every family whatever its
  value — a mode or an action name — route it `:raw` in `call_routes:` (see `Mutare.CallRouting`).

  Interpolated quoted atoms (`:"a\#{x}b"`) are mutated as a whole to the sentinel — their runtime value can never statically be `:mutare`, so the swap always applies — while the expressions inside the interpolation stay eligible for their own mutations, mirroring how `Mutare.Mutators.StringLiteral` treats interpolated strings.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @sentinel AST.sentinel_atom()

  # Convention atoms (`:ok`/`:error`, …) are owned by `Mutare.Mutators.ConventionAtom`,
  # which swaps each for its high-signal same-shape sibling rather than the sentinel — so
  # they are excluded here, the way `true`/`false` are deferred to `BooleanLiteral` (and
  # `nil` is left alone). Single source of truth: the list lives with that family (the
  # `@sentinel AST.sentinel_atom()` pattern). As with the boolean/nil split, disabling
  # `:convention` leaves these atoms unmutated by `:atom` too.
  @convention Mutare.Mutators.ConventionAtom.members()

  @impl Mutare.Mutator
  def name, do: :atom

  @impl Mutare.Mutator
  def mutate_call_option_keys?(opts) do
    not (Keyword.keyword?(opts) and Keyword.get(opts, :call_option_keys, true) == false)
  end

  # Reuse `IntegerLiteral`'s timeout table so `:infinity` is left alone at exactly the positions
  # `IntegerLiteral` leaves a numeric duration alone. Declaring it here too (rather than reading
  # `IntegerLiteral`'s marks) keeps the suppression working when `:integer` is disabled but `:atom`
  # is not — the mark must exist for this family to react to it. `IntegerLiteral.timeout_marks/0` is
  # a pure table, callable whether or not `IntegerLiteral` is an active mutator.
  @impl Mutare.Mutator
  def argument_marks(_config), do: Mutare.Mutators.IntegerLiteral.timeout_marks()

  # Decline for `:infinity` at a marked timeout position — the "wait forever" duration, not a value
  # to perturb. A *different* atom there is not a duration and still mutates
  # (`Task.shutdown(t, :brutal_kill)`): the reaction is value-aware, which is what a mark buys over
  # a `:raw` route. `mutate/2` takes precedence at dispatch.
  @impl Mutare.Mutator
  def mutate(node, context) do
    if infinity_timeout?(node, context), do: :skip, else: mutate(node)
  end

  defp infinity_timeout?({:__block__, _meta, [:infinity]}, context),
    do: Mutare.Mutator.marked?(context, :timeout)

  defp infinity_timeout?(_node, _context), do: false

  @impl Mutare.Mutator
  # `true`/`false`/`nil` are atom literals but belong elsewhere (see @moduledoc).
  def mutate({:__block__, _meta, [a]}) when is_boolean(a) or is_nil(a), do: :skip

  # A convention atom is owned by `ConventionAtom` (see @moduledoc).
  def mutate({:__block__, _meta, [a]}) when a in @convention, do: :skip

  # Any other literal atom → the sentinel, unless it already is the sentinel.
  def mutate({:__block__, _meta, [a]}) when is_atom(a) and a != @sentinel,
    do: [AST.literal(@sentinel)]

  # An interpolated quoted atom (`:"a#{x}b"`) parses as an `:erlang.binary_to_atom/2` call
  # carrying the parser's `:delimiter` meta — the gate that separates atom *syntax* from a
  # hand-written call to the same function (no delimiter: not a literal, skipped). Its
  # runtime value can never statically be the sentinel, so the swap always applies.
  def mutate({{:., _dot, [:erlang, :binary_to_atom]}, meta, [{:<<>>, _bmeta, _segments}, _enc]}) do
    if Keyword.has_key?(meta, :delimiter), do: [AST.literal(@sentinel)], else: :skip
  end

  def mutate(_node), do: :skip
end
