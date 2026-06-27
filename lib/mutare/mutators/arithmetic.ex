defmodule Mutare.Mutators.Arithmetic do
  @moduledoc """
  Arithmetic operator swaps: `+`↔`-`, `*`↔`/`, `div`↔`rem`, plus unary-minus
  removal (`-x` → `x`).

  On by default. `div`/`rem` are guard-legal, so a `div`/`rem` in a `when` guard is
  mutated too. `div`/`rem` are also pipe-aware (`x |> div(y)` → `x |> rem(y)`).

  ## Unary-minus removal (`-x` → `x`)

  The classic "invert negatives" mutation: a sign flip the suite should notice.
  `-0` (a literal zero) is skipped — `-0 == 0`, so the mutant is equivalent. (`-0.0`
  is *not* skipped: dropping the unary minus normalizes negative zero, an observable
  change.)

  ## Multiplicative identity is skipped

  `a * 1` and `a / 1` are skipped — swapping `*`↔`/` there leaves the value
  unchanged, an equivalent mutant. Only the **right** operand qualifies: `1 * a` →
  `1 / a` is a reciprocal, a real change.

  Caveat (rare, `==`-invisible): `/` always yields a float, so for integer `a`,
  `a * 1` and `a / 1` differ in *type* — equal under `==`, not under `===`. Treated
  as equivalent for scoring.

  ## Additive identity is NOT skipped

  `a + 0` and `a - 0` are deliberately kept as mutants. Adding/subtracting a literal
  zero has one genuine, test-observable use: normalizing floating-point negative zero
  (`x + 0.0` turns `-0.0` into `0.0`, but `x - 0.0` keeps it) — so the `+`↔`-` mutant
  is surfaced as the check that an author actually tests the result.

  `div`/`rem` are never identities either: `div(a, 1)` is `a`, but `rem(a, 1)`
  is always `0`.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to
  suppress just one kind (`c:Mutare.Mutator.variants/0`): `+`, `-`, `*`, `/`, `div`, `rem`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.Helpers

  # Genuine binary *operators* — always written infix (arity 2, never piped), so an
  # arity-blind `mutate/1` is safe. (`div`/`rem` are *calls*, handled in `mutate/2`.)
  @swaps %{
    :+ => [:-],
    :- => [:+],
    :* => [:/],
    :/ => [:*]
  }

  # Bare `Kernel` `div`/`rem` calls keyed on {name, effective_arity} => [sibling] — the same
  # shared bare-`Kernel` safeguard `Mutare.Mutators.Numeric` uses (`Helpers.swap_bare_kernel/3`):
  # the arity proves a bare `div` is the Kernel `div/2` (not a user `div/3`), and a call
  # displaced by `import Kernel, except: [div: 2]` is skipped.
  @call_swaps %{
    {:div, 2} => [:rem],
    {:rem, 2} => [:div]
  }

  # operator => right-operand value that makes the swap an equivalent no-op
  @identity %{:* => 1, :/ => 1}

  @impl Mutare.Mutator
  def name, do: :arithmetic

  @impl Mutare.Mutator
  # Unary minus (arity 1) — drop the negation, except on an *integer* literal zero.
  # `-0 === 0` (there is no negative integer zero), so that mutant is equivalent and
  # skipped. But `-0.0` is NOT `0.0`: dropping the unary minus normalizes negative
  # zero, an observable change (distinct `Float.to_string`, distinct sign in `1 / x`,
  # and `-0.0 !== 0.0` on OTP 27+) — the same negative-zero behavior the binary
  # additive-identity path deliberately keeps. So the skip uses `===`, not `==`
  # (`0.0 == 0` is `true`, `0.0 === 0` is `false`).
  def mutate({:-, _meta, [operand]}) do
    if AST.literal_value(operand) === {:ok, 0}, do: :skip, else: [operand]
  end

  def mutate({op, meta, [left, right]}) do
    case Map.fetch(@swaps, op) do
      {:ok, replacements} ->
        if identity_swap?(op, right) do
          :skip
        else
          Enum.map(replacements, &{&1, meta, [left, right]})
        end

      :error ->
        :skip
    end
  end

  def mutate(_node), do: :skip

  # `div`/`rem` are bare `Kernel` calls, not operators. Swapping `div`↔`rem` keeps the
  # argument list, so it is a valid rename at any position (a pipe stage included), gated on
  # **effective arity 2** so a same-named user `div/3` is never rewritten to a `rem/3` that may
  # not exist (which would poison the single build) — the shared bare-`Kernel` safeguard
  # (`Helpers.swap_bare_kernel/3`, also used by `Numeric`).
  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}),
    do: Helpers.swap_bare_kernel(node, pipe_mode, @call_swaps)

  # Variant labels for `# mutare:ignore[arithmetic:<op>]`: the resulting operator of a binary
  # swap (`a - b` → `a + b` is the `+` variant, classified by the shared `op_swap_variant/3` over
  # `@swap_ops`) or a `div`/`rem` rename (its own clause — a bare-`Kernel` call, not an operator
  # node). The unary-minus strip (`-x` → `x`) stays unlabeled: its unary original can't be a swap,
  # so the strip's `{:+, …}` output (e.g. from `-(a + b)`) is never mis-read as a `+` swap. Both
  # sets are derived from the mutate tables (`@swaps`/`@call_swaps`), so the vocabulary, the
  # classifier, and the actual swaps single-source one set and can't drift.
  @swap_ops Map.keys(@swaps)
  # `@call_swaps` is keyed on `{name, arity}` (the shared bare-`Kernel` safeguard), so take just
  # the function names — the label is the resulting call's name (`div`/`rem`), arity-blind.
  @call_funs @call_swaps |> Map.keys() |> Enum.map(&elem(&1, 0))

  @impl Mutare.Mutator
  def variants, do: Enum.map(@swap_ops ++ @call_funs, &to_string/1)

  @impl Mutare.Mutator
  def variant({fun, _m, args}, {new, _m2, _args2})
      when fun in @call_funs and new in @call_funs and is_list(args),
      do: to_string(new)

  def variant(original, mutated), do: Mutare.Mutator.op_swap_variant(original, mutated, @swap_ops)

  defp identity_swap?(op, right) do
    case Map.fetch(@identity, op) do
      {:ok, identity} -> AST.literal_value(right) == {:ok, identity}
      :error -> false
    end
  end
end
