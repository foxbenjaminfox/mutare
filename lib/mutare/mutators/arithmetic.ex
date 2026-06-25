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
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  # Genuine binary *operators* — always written infix (arity 2, never piped), so an
  # arity-blind `mutate/1` is safe. (`div`/`rem` are *calls*, handled in `mutate/2`.)
  @swaps %{
    :+ => [:-],
    :- => [:+],
    :* => [:/],
    :/ => [:*]
  }

  # Bare `Kernel` call-form swaps, offered only at effective arity 2 — the same
  # bare-`Kernel` safeguard `Mutare.Mutators.Numeric` uses (see `mutate/2`).
  @call_swaps %{
    div: [:rem],
    rem: [:div]
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
  # argument list, so it is a valid rename at any position (a pipe stage included). The
  # swap is gated on **effective arity 2** (pipe-aware, like the bare-`Kernel` rule in
  # `Mutare.Mutators.Numeric`): a same-named user `div/3` is never rewritten to a `rem/3`
  # that may not exist — which would poison the single build. A pipe stage carries one
  # fewer arg than the source reads (`x |> div(y)` is `div/2`), so the flag recovers it.
  @impl Mutare.Mutator
  def mutate({fun, meta, args}, %{pipe_mode: pipe_mode})
      when fun in [:div, :rem] and is_list(args) do
    if Mutare.Mutator.effective_arity(args, pipe_mode) == 2 do
      Enum.map(Map.fetch!(@call_swaps, fun), &{&1, meta, args})
    else
      :skip
    end
  end

  def mutate(_node, _context), do: :skip

  defp identity_swap?(op, right) do
    case Map.fetch(@identity, op) do
      {:ok, identity} -> AST.literal_value(right) == {:ok, identity}
      :error -> false
    end
  end
end
