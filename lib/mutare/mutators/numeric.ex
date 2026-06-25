defmodule Mutare.Mutators.Numeric do
  @moduledoc """
  Swap a numeric `Kernel`/`Float` builtin for its complementary sibling — the
  arithmetic cousin of `Mutare.Mutators.Collection`/`StringCall`, asking: does any
  test actually depend on *which* selection or rounding direction this call uses?

    * `min/2` ↔ `max/2`              — the bound it selects (the `Kernel` twins of
      `Enum.min`/`max`, which `Collection` already covers)
    * `round/1` ↔ `trunc/1`          — round-to-nearest vs truncate-toward-zero
    * `ceil/1` ↔ `floor/1`           — round up vs round down
    * `Float.ceil` ↔ `Float.floor`   — the float-precision pair (any arity)
    * `Float.max_finite` ↔ `Float.min_finite` — the extreme-finite-float pair
      (`/0` constants returning the largest/smallest representable float; an
      arity-blind rename like the `Float.ceil`/`floor` pair, the two extremes of
      the finite range)

  The `Kernel` functions (`min`/`max`/`round`/`trunc`/`ceil`/`floor`) are all guard-safe,
  so a swap is mutated even inside a `when`.

  ## Complementary pairs, not a full mesh

  `round`/`trunc`/`ceil`/`floor` all coerce a number to an integer and differ only in
  rounding *direction*, so they could in principle each map to the other three. Only the
  two **complementary pairs** (`round`↔`trunc`, `ceil`↔`floor`) are offered, not the full
  mesh: a mesh would triple the mutant count at every rounding call and surface more
  *equivalent* survivors (for a positive non-integer `x`, `floor(x) == trunc(x)`, so that
  swap is a no-op the suite can never kill). The two pairs capture the two questions worth
  asking: nearest-vs-truncate, and up-vs-down.

  ## Scope and known gaps

  Matches aliased and bare-imported calls too. A bare `Kernel` call is swapped only at
  its true arity (min/max `/2`, the coercions `/1`), so a same-named user `floor/2` or
  `max/3` is left alone, and a `Kernel` function displaced by `import Kernel, except:`
  is skipped. `Float.round` is intentionally absent — round-to-nearest has no
  complementary `Float` sibling. `div`↔`rem` lives in `Mutare.Mutators.Arithmetic` (it is
  an operator swap, not a call). On by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # Bare `Kernel` calls keyed on {name, effective_arity} => [sibling names]. The arity
  # is what proves a bare `floor`/`max` is the Kernel one (and not a same-named user
  # function at a different arity), so each entry pins it: min/max are /2, the rounding
  # coercions /1.
  # Keep in sync with the `{[:Kernel], …}` entries of `@remote_swaps` (the qualified forms of
  # these same bare swaps) — a new bare-Kernel numeric swap belongs in both tables.
  @kernel_swaps %{
    {:min, 2} => [:max],
    {:max, 2} => [:min],
    {:round, 1} => [:trunc],
    {:trunc, 1} => [:round],
    {:ceil, 1} => [:floor],
    {:floor, 1} => [:ceil]
  }

  # **Qualified** calls: an arity-blind remote rename (the qualifier proves the function,
  # and every sibling exists at the same arity), exactly like `Collection`. Both the
  # `Float` precision pair and the explicitly-`Kernel.`-qualified forms of the bare swaps.
  # {alias_path, function} => new_function. Keep the `{[:Kernel], …}` entries in sync with
  # `@kernel_swaps`.
  @remote_swaps %{
    {[:Float], :ceil} => :floor,
    {[:Float], :floor} => :ceil,
    {[:Float], :max_finite} => :min_finite,
    {[:Float], :min_finite} => :max_finite,
    {[:Kernel], :min} => :max,
    {[:Kernel], :max} => :min,
    {[:Kernel], :round} => :trunc,
    {[:Kernel], :trunc} => :round,
    {[:Kernel], :ceil} => :floor,
    {[:Kernel], :floor} => :ceil
  }

  @impl Mutare.Mutator
  def name, do: :numeric

  # A qualified `Float.ceil`/`floor` or `Kernel.min`/`max`/`round`/`trunc`/`ceil`/`floor`:
  # an arity-blind remote rename — the swap keeps the argument list and the sibling exists
  # at the same arity, so no pipe context is needed.
  @impl Mutare.Mutator
  def mutate(node), do: Helpers.swap_call(node, @remote_swaps)

  # Bare `Kernel` `min`/`max`/`round`/`trunc`/`ceil`/`floor`: the swap is offered only at the
  # function's true (effective) arity, and a `Kernel`-displaced call is skipped — the shared
  # bare-`Kernel` safeguard (`Helpers.swap_bare_kernel/3`, also used by `Arithmetic`'s div/rem).
  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}),
    do: Helpers.swap_bare_kernel(node, pipe_mode, @kernel_swaps)
end
