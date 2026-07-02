defmodule Mutare.Mutators.Numeric do
  @moduledoc """
  Renames numeric selection and rounding calls to a complementary function:

    * `Kernel.min/2` ↔ `Kernel.max/2`
    * `Kernel.round/1` ↔ `Kernel.trunc/1`
    * `Kernel.ceil/1` ↔ `Kernel.floor/1`
    * `Float.ceil` ↔ `Float.floor` at any arity
    * `Float.max_finite/0` ↔ `Float.min_finite/0`

  Only the listed pairs are produced. In particular, the four integer-returning rounding functions are not treated as a full set because some cross-pair replacements are equivalent for common inputs. `Float.round` is not included because it has no complementary `Float` function.

  Kernel calls are matched only at their defined arities and may also be mutated in guards. Aliased and imported calls are supported; a Kernel function displaced by an import is not matched. The `div`/`rem` pair belongs to `Mutare.Mutators.Arithmetic`.

  This family is enabled by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

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

  # The `Float` precision pairs: an arity-blind remote rename (the qualifier proves the
  # function, and every sibling exists at the same arity), exactly like `Collection`.
  @float_swaps %{
    {[:Float], :ceil} => :floor,
    {[:Float], :floor} => :ceil,
    {[:Float], :max_finite} => :min_finite,
    {[:Float], :min_finite} => :max_finite
  }

  # The explicitly-`Kernel.`-qualified forms of the bare swaps, **derived** from
  # `@kernel_swaps` so the two tables can't drift: each `{fun, arity} => siblings` bare entry
  # becomes a `{[:Kernel], fun} => siblings` qualified entry. A new bare-Kernel numeric swap
  # added to `@kernel_swaps` therefore gets its qualified form for free — including a future
  # multi-sibling entry (`Helpers.swap_call`/`swap_resolved` `List.wrap`s the value, so a list
  # is as valid as a bare atom here). Keeping the whole `siblings` value also avoids the
  # silent-skip a `[sibling]` destructure would hide if an entry ever had more than one.
  @kernel_remote_swaps for {{fun, _arity}, siblings} <- @kernel_swaps,
                           into: %{},
                           do: {{[:Kernel], fun}, siblings}

  # **Qualified** calls: the `Float` precision pairs plus the qualified Kernel forms.
  # {alias_path, function} => new_function.
  @remote_swaps Map.merge(@float_swaps, @kernel_remote_swaps)

  @impl Mutare.Mutator
  def name, do: :numeric

  # A qualified `Float.ceil`/`floor` or `Kernel.min`/`max`/`round`/`trunc`/`ceil`/`floor`:
  # an arity-blind remote rename — the swap keeps the argument list and the sibling exists
  # at the same arity, so the private helper can handle it. `mutate/2` explicitly
  # composes this helper with the bare-Kernel path below.
  defp qualified_mutations(node), do: Helpers.swap_call(node, @remote_swaps)

  # Compose the arity-blind qualified-call mutations with the context-aware bare-`Kernel`
  # mutations explicitly in the single exported mutation callback.
  #
  # Bare `Kernel` `min`/`max`/`round`/`trunc`/`ceil`/`floor`: the swap is offered only at the
  # function's true (effective) arity, and a `Kernel`-displaced call is skipped — the shared
  # bare-`Kernel` safeguard (`Helpers.swap_bare_kernel/3`, also used by `Arithmetic`'s div/rem).
  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}),
    do:
      Helpers.combine_mutations(
        qualified_mutations(node),
        Helpers.swap_bare_kernel(node, pipe_mode, @kernel_swaps)
      )
end
