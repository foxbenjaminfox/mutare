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
  alias Mutare.Mutators.Helpers
  alias Mutare.Transform.Calls

  # {module, fun} => sibling fun(s), the shared swap-table shape (`Helpers.swap_call/2`, the
  # same `{module_key, fun}` keying `Collection`/`Numeric` use). Every sibling exists at the
  # same arity in `:math`, so an arity-blind rename keeping the argument list always compiles.
  @swaps %{
    {:math, :sin} => [:cos],
    {:math, :cos} => [:sin],
    {:math, :asin} => [:acos],
    {:math, :acos} => [:asin],
    {:math, :sinh} => [:cosh],
    {:math, :cosh} => [:sinh],
    {:math, :asinh} => [:acosh],
    {:math, :acosh} => [:asinh],
    {:math, :log} => [:log2, :log10],
    {:math, :log2} => [:log, :log10],
    {:math, :log10} => [:log, :log2]
  }

  # 0-arity constant functions → a nearby-but-wrong float literal.
  @constants %{pi: 3.0, tau: 6.0}

  @impl Mutare.Mutator
  def name, do: :math

  # A `/0` constant (`:math.pi()`/`tau()`) collapses to a nearby-but-wrong float literal
  # (gated on the empty arg list, so a hypothetical same-named call *with* arguments is never
  # collapsed); every other `:math` call is an arity-blind sibling rename through the shared
  # swap table (`Helpers.swap_call/2`, which resolves direct/aliased/bare-imported forms and
  # rebuilds in the written module).
  @impl Mutare.Mutator
  def mutate(node) do
    with {:math, fun, [], _rebuild} <- Calls.resolved_call(node),
         {:ok, value} <- Map.fetch(@constants, fun) do
      [AST.literal(value)]
    else
      _ -> Helpers.swap_call(node, @swaps)
    end
  end
end
