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

  Every swap keeps the argument list and lands on a function of the **same arity**,
  so the single metamutant build always compiles. The `Kernel` functions
  (`min`/`max`/`round`/`trunc`/`ceil`/`floor`) are all guard-safe, so a swap is legal
  even inside a `when` (delivered by lifting), and `Float` calls are remote — never
  guard-legal — so guard-safety is automatic there too.

  ## Complementary pairs, not a full mesh

  `round`/`trunc`/`ceil`/`floor` all coerce a number to an integer and differ only in
  rounding *direction*, so they could in principle each map to the other three. We
  deliberately offer only the two **complementary pairs** (`round`↔`trunc`,
  `ceil`↔`floor`) rather than the full mesh — matching the curated-pair aesthetic of
  `Collection`/`StringCall` and `ModeSwap`'s "one adjacent step". A mesh would triple
  the mutant count at every rounding call and surface more *equivalent* survivors (for
  a positive non-integer `x`, `floor(x) == trunc(x)`, so that swap is a no-op the suite
  can never kill), trading signal for noise. The two pairs capture the two questions
  worth asking: nearest-vs-truncate, and up-vs-down.

  ## Qualified vs bare calls (why one path is pipe-aware)

  A **qualified** call — `Float.ceil(x)`, `Kernel.min(a, b)`, or any pipe stage of one —
  carries the module prefix that proves which function it is, so the swap is a pure
  **arity-blind rename** (each sibling exists at the same arity: `Kernel.min/max` only at
  `/2`, the coercions only at `/1`, `Float.ceil/floor` at `/1` and `/2`). That is handled
  in `mutate/1` exactly like `Collection`/`StringCall`, ignoring arity and pipe position
  entirely.

  A **bare** `Kernel` call (`max(a, b)`, `floor(x)`) has no prefix, so there is nothing to
  prove the call is the `Kernel` one rather than a same-named local/imported function. The
  safeguard is **arity**: a swap is offered only at the matching arity (min/max `/2`, the
  coercions `/1`), so a user's `floor/2` or `max/3` is left alone, never swapped to a
  sibling that might not exist at that arity (which would poison the build). Recovering
  the true arity needs the pipe flag — a pipe stage carries one fewer argument than the
  source reads (`x |> max(0)` reaches a mutator as a 1-arg `max(0)` whose effective arity
  is 2) — so, like `Mutare.Mutators.CollectionArity`/`ModeSwap`, the bare-`Kernel` rule is
  keyed on **effective arity** (`length(args) + if(piped, do: 1, else: 0)`) in `mutate/2`.

  ## Scope and known gaps

  The qualified `Float`/`Kernel` forms are recognised by their **resolved** module
  (`Mutare.Transform.Aliases`), so an aliased `F.ceil` (`alias Float, as: F`) is matched.
  Bare `Kernel` calls can't be aliased; an `import` that rebinds them is not resolved (out
  of scope — see `Mutare.Transform.Aliases`). `Float.round` is intentionally absent —
  round-to-nearest has no complementary `Float` sibling. `div`↔`rem` lives in
  `Mutare.Mutators.Arithmetic` (it is an operator swap, not a call). On by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Aliases

  # Bare `Kernel` calls keyed on {name, effective_arity} => [sibling names]. The arity
  # is what proves a bare `floor`/`max` is the Kernel one (and not a same-named user
  # function at a different arity), so each entry pins it: min/max are /2, the rounding
  # coercions /1.
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
  # {alias_path, function} => {alias_path, function}.
  @remote_swaps %{
    {[:Float], :ceil} => {[:Float], :floor},
    {[:Float], :floor} => {[:Float], :ceil},
    {[:Kernel], :min} => {[:Kernel], :max},
    {[:Kernel], :max} => {[:Kernel], :min},
    {[:Kernel], :round} => {[:Kernel], :trunc},
    {[:Kernel], :trunc} => {[:Kernel], :round},
    {[:Kernel], :ceil} => {[:Kernel], :floor},
    {[:Kernel], :floor} => {[:Kernel], :ceil}
  }

  @impl Mutare.Mutator
  def name, do: :numeric

  # A qualified `Float.ceil`/`floor` or `Kernel.min`/`max`/`round`/`trunc`/`ceil`/`floor`:
  # an arity-blind remote rename — the swap keeps the argument list and the sibling exists
  # at the same arity, so no pipe context is needed.
  @impl Mutare.Mutator
  def mutate({{:., dot_meta, [{:__aliases__, alias_meta, mod} = aliases, fun]}, call_meta, args})
      when is_list(args) do
    case Map.fetch(@remote_swaps, {Aliases.resolved_module(alias_meta, mod), fun}) do
      {:ok, {_new_mod, new_fun}} ->
        # Reuse the literal alias node (the swap stays within `Float`/`Kernel`).
        [{{:., dot_meta, [aliases, new_fun]}, call_meta, args}]

      :error ->
        :skip
    end
  end

  def mutate(_node), do: :skip

  # Bare `Kernel` `min`/`max`/`round`/`trunc`/`ceil`/`floor`: the swap is offered only at
  # the function's true (effective) arity, so a same-named user call at another arity is
  # never mutated. Pipe-aware because a pipe stage's node carries one fewer arg than the
  # source reads.
  @impl Mutare.Mutator
  def mutate({fun, meta, args}, %{piped: piped?})
      when is_atom(fun) and is_list(args) do
    eff_arity = Mutare.Mutator.effective_arity(args, piped?)

    case Map.fetch(@kernel_swaps, {fun, eff_arity}) do
      {:ok, siblings} -> Enum.map(siblings, &{&1, meta, args})
      :error -> :skip
    end
  end

  def mutate(_node, _context), do: :skip
end
