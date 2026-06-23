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

  The constant swaps (`pi`/`tau`, both `/0`) replace the whole call with a plain float
  literal that is the right shape but the wrong value — a magnitude any test pinning down
  the geometry will catch.

  On by default. Matches the direct `:math.sin`, an aliased `alias :math, as: M; M.sin`,
  and a bare imported `import :math; sin` alike.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Transform.Calls

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
  def mutate(node) do
    case Calls.resolved_call(node) do
      {:math, fun, args, rebuild} -> mutate_math(fun, args, rebuild)
      _other -> :skip
    end
  end

  defp mutate_math(fun, args, rebuild) do
    cond do
      # `:math.pi()`/`tau()` are `/0`; gate on the empty arg list so a hypothetical
      # same-named call with arguments is never collapsed to a constant.
      Map.has_key?(@constants, fun) and args == [] ->
        [AST.literal(Map.fetch!(@constants, fun))]

      # `rebuild` keeps the written module (`:math`, an alias, or bare import).
      Map.has_key?(@swaps, fun) ->
        for new_fun <- Map.fetch!(@swaps, fun), do: rebuild.(new_fun, args)

      true ->
        :skip
    end
  end
end
