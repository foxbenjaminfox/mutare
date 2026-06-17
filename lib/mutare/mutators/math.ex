defmodule Mutare.Mutators.Math do
  @moduledoc """
  Mutate calls to the Erlang `:math` module — the floating-point cousin of
  `Mutare.Mutators.Numeric`, asking: does any test actually depend on *which*
  trigonometric/logarithmic function (or constant) this call computes?

    * `:math.pi()`  → `3.0`                  — a nearby-but-wrong constant
    * `:math.tau()` → `6.0`                  — likewise (τ = 2π)
    * `:math.sin`   ↔ `:math.cos`            — co-function swaps
    * `:math.asin`  ↔ `:math.acos`
    * `:math.sinh`  ↔ `:math.cosh`
    * `:math.asinh` ↔ `:math.acosh`
    * `:math.log` ↔ `:math.log2` ↔ `:math.log10` — the logarithm-base trio (each
      maps to the other two)

  Every function in a swap group exists at the **same arity** in `:math` (the
  trig/hyperbolic/log functions are all `/1`), so renaming while keeping the
  argument list always compiles. The constant swaps (`pi`/`tau`, both `/0`) replace
  the whole call with a plain float literal that is the right shape but the wrong
  value — a magnitude any test pinning down the geometry will catch.

  `:math` is matched on the **literal atom**. The atom form `:math.sin` can't be
  *shadowed* — `:math` always names the Erlang module — so the match is unambiguous
  (no false mutation, no need for the arity/`import` safeguards `Numeric` carries for
  bare `Kernel` calls). An `alias :math, as: M` *does* compile, but the alias pre-pass
  resolves only Elixir-module (`__aliases__`) aliases, so the aliased `M.sin` form is
  not seen through (only the direct `:math.foo` is matched) — an accepted gap, since
  `:math` is overwhelmingly written directly. Every `:math` function is a remote call
  (never guard-legal), so guard-safety is automatic and these are always delivered in
  place. On by default.
  """
  @behaviour Mutare.Mutator

  # fun => sibling fun(s) to swap to. Every sibling exists at the same arity in
  # `:math`, so an arity-blind rename keeping the argument list always compiles.
  @swaps %{
    sin: [:cos],
    cos: [:sin],
    asin: [:acos],
    acos: [:asin],
    sinh: [:cosh],
    cosh: [:sinh],
    asinh: [:acosh],
    acosh: [:asinh],
    log: [:log2, :log10],
    log2: [:log, :log10],
    log10: [:log, :log2]
  }

  # 0-arity constant functions → a nearby-but-wrong float literal.
  @constants %{pi: 3.0, tau: 6.0}

  @impl Mutare.Mutator
  def name, do: :math

  @impl Mutare.Mutator
  def mutate({{:., dot_meta, [mod, fun]}, call_meta, args}) when is_list(args) do
    cond do
      not math_module?(mod) ->
        :skip

      # `:math.pi()`/`tau()` are `/0`; gate on the empty arg list so a hypothetical
      # same-named call with arguments is never collapsed to a constant.
      Map.has_key?(@constants, fun) and args == [] ->
        [literal(Map.fetch!(@constants, fun))]

      Map.has_key?(@swaps, fun) ->
        for new_fun <- Map.fetch!(@swaps, fun),
            do: {{:., dot_meta, [mod, new_fun]}, call_meta, args}

      true ->
        :skip
    end
  end

  def mutate(_node), do: :skip

  # Sourceror wraps the atom module as `{:__block__, _, [:math]}`; accept a bare
  # `:math` too so the mutator is robust to either quoting.
  defp math_module?({:__block__, _meta, [:math]}), do: true
  defp math_module?(:math), do: true
  defp math_module?(_node), do: false

  # Fresh metadata so Sourceror renders the value, not a stale `:token` from the
  # original (the clean-meta rule that bites every literal-valued mutator).
  defp literal(value), do: {:__block__, [], [value]}
end
