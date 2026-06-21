defmodule Mutare.Mutators.Bitwise do
  @moduledoc """
  Bitwise operator/function swaps — the bit-twiddling sibling of
  `Mutare.Mutators.Arithmetic`, asking: does any test actually depend on *which*
  bitwise combination this does?

    * `&&&` ↔ `|||`   (band ↔ bor)       — the AND/OR pair
    * `<<<` ↔ `>>>`   (bsl ↔ bsr)        — the shift-left/right pair
    * `~~~x` → `x`    (bnot)             — drop the complement, the bitwise twin of
      Arithmetic's unary-minus removal

  Both spellings are covered: the **operators** (`a &&& b`, `~~~x`) and the
  **function** forms (`Bitwise.band(a, b)`, `import Bitwise; bsl(x, n)`,
  `Bitwise.bnot(x)`).

  ## Operators vs functions (one path each)

  `&&&`/`|||`/`<<<`/`>>>` (and the legacy `~~~`) parse as genuine infix operators —
  `a &&& b` is `{:&&&, _, [a, b]}` — *whether or not* `Bitwise` is imported (the import
  only governs whether they compile), exactly like `+`/`-`. So an arity-blind `mutate/1`
  swap is safe: they are always written at arity 2 (1 for `~~~`), never a pipe stage.

  The **function** forms are resolved through `Mutare.Transform.Calls`, so a direct
  `Bitwise.band(a, b)`, an aliased `B.band(a, b)` (`alias Bitwise, as: B`), and a bare
  `import Bitwise; band(a, b)` all match. Unlike `div`/`rem` (bare `Kernel` calls that
  need arity-gating against same-named user functions — see `Mutare.Mutators.Arithmetic`),
  `Bitwise` is never auto-imported, so a resolved `band`/`bsl`/… *is* the `Bitwise` one and
  the swaps are arity-blind renames (`band`↔`bor`, `bsl`↔`bsr` exist at the same arity).
  That makes them pipe-safe for free (`x |> bsl(n)` → `x |> bsr(n)`), so no `mutate/2` /
  effective-arity bookkeeping is needed.

  All bitwise operators and functions are **guard-legal**, so a swap inside a `when` is
  delivered by lifting (like Arithmetic's `-`/`/`); placement is positional, not the
  mutator's concern.

  ## Equivalent shifts are skipped

  A shift by a literal `0` is an identity in *both* directions (`x <<< 0 == x == x >>> 0`),
  so swapping `<<<`↔`>>>` (or `bsl`↔`bsr`) there is an equivalent no-op — skipped, mirroring
  Arithmetic's multiplicative-identity skip. The AND/OR pair has no such literal identity
  (`x &&& 0 == 0` but `x ||| 0 == x`, and with `-1` the reverse), so those are always
  offered. `~~~x` is never equivalent to `x` (`~~~x == -x - 1`), so it is always offered.

  ## Scope and known gaps

  `bxor`/`^^^` are left alone — XOR has no natural complementary sibling, so swapping it to
  AND or OR would be an arbitrary mapping, trading signal for noise (the curated-pair
  aesthetic of `Mutare.Mutators.Numeric`). `~~~` and `^^^` are the *deprecated* operators
  (the compiler nudges toward `Bitwise.bnot/1`/`bxor/2`); we still strip a `~~~` that
  compiles, but the primary complement form is the function `bnot`. A `bnot` **as a pipe
  stage** (`x |> bnot()`, whose node has no visible argument) is not stripped — a rare,
  safe miss. `use Bitwise` injects its imports via macro expansion, invisible without
  expanding it (the same limitation `Mutare.Transform.Imports` documents). On by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Calls

  # Binary *operator* swaps. Keys are the operator atoms the parser emits, regardless of
  # whether `Bitwise` is imported, so an arity-blind `mutate/1` swap is sound.
  @op_swaps %{
    :&&& => :|||,
    :||| => :&&&,
    :<<< => :>>>,
    :>>> => :<<<
  }

  # The shift operators/functions, whose swap is an equivalent no-op when the shift amount
  # is a literal `0` (both directions are identity).
  @shift_ops [:<<<, :>>>]

  # Binary *function* swaps, keyed on the resolved function name (the module is always
  # `[:Bitwise]`, pinned at the match site). Same pairs as `@op_swaps`, as calls.
  @call_swaps %{
    band: :bor,
    bor: :band,
    bsl: :bsr,
    bsr: :bsl
  }

  @shift_calls [:bsl, :bsr]

  @impl Mutare.Mutator
  def name, do: :bitwise

  # `~~~x` (operator) — drop the complement.
  @impl Mutare.Mutator
  def mutate({:"~~~", _meta, [operand]}), do: [operand]

  # `&&&`/`|||`/`<<<`/`>>>` (operators) — swap for the complementary operator, skipping a
  # shift by a literal `0` (an equivalent no-op).
  def mutate({op, meta, [left, right]}) when op in [:&&&, :|||, :<<<, :>>>] do
    if op in @shift_ops and literal_zero?(right) do
      :skip
    else
      [{Map.fetch!(@op_swaps, op), meta, [left, right]}]
    end
  end

  # Everything else: a bitwise *function* call (`Bitwise.band`, aliased, or imported).
  def mutate(node), do: swap_or_strip_call(node)

  # Resolve the node through `Mutare.Transform.Calls` and, if it is a `Bitwise` call we
  # handle, rename it to the complementary function (or, for `bnot`, strip the complement).
  defp swap_or_strip_call(node) do
    case Calls.resolved_call(node) do
      {[:Bitwise], :bnot, [operand], _rebuild} ->
        [operand]

      {[:Bitwise], fun, args, rebuild} when fun in [:band, :bor, :bsl, :bsr] ->
        if fun in @shift_calls and literal_zero?(List.last(args)) do
          :skip
        else
          [rebuild.(Map.fetch!(@call_swaps, fun), args)]
        end

      _ ->
        :skip
    end
  end

  # A literal integer `0`, in raw or Sourceror-wrapped (`{:__block__, _, [0]}`) form.
  defp literal_zero?(0), do: true
  defp literal_zero?({:__block__, _meta, [0]}), do: true
  defp literal_zero?(_node), do: false
end
