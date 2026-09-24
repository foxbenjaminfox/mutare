defmodule Mutare.Test.BindingOracle do
  @moduledoc """
  The callees of the binding-reader oracle (`bindings_oracle_property_test.exs`): one for each
  way a call may depart from a function that the routing vocabulary has a word for, written
  as the macro Elixir will expand — so the compiler's own scoping is what each word's
  declaration is checked against.

    * `pair/2` — an ordinary function: siblings.
    * `id/1` — an ordinary function under a configured `:skip`: withheld from mutation,
      evaluated as written.
    * `twice/1` (`:lazy_expression`) — evaluates its argument twice, as two statements.
    * `maybe/2` (`[:lazy_expression, :expression]`) — evaluates its first argument only when
      the second is truthy, in a branch.
    * `reversed/2` (`[:lazy_expression, :lazy_expression]`) — runs its second argument
      before its first, as statements.
    * `unpack/2` (`:routing`) — `destructure/2` behind a classifier, so that under a skipped
      wrapper the route is withheld and the call reads as `:unknown`.
  """
  @behaviour Mutare.CallRouting

  @impl Mutare.CallRouting
  def call_routes do
    [
      {__MODULE__, :id, 1, :skip},
      {__MODULE__, :twice, 1, :lazy_expression},
      {__MODULE__, :maybe, 2, [:lazy_expression, :expression]},
      {__MODULE__, :reversed, 2, [:lazy_expression, :lazy_expression]},
      {__MODULE__, :unpack, 2, :routing}
    ]
  end

  @impl Mutare.CallRouting
  def route_arguments(call),
    do: Mutare.CallRouting.ArgumentRoutes.new(call, [:binding_pattern, :expression])

  def pair(left, right), do: {left, right}
  def id(value), do: value

  defmacro twice(expr) do
    quote do
      unquote(expr)
      unquote(expr)
    end
  end

  defmacro maybe(expr, on?) do
    quote do
      if unquote(on?), do: unquote(expr), else: :skipped
    end
  end

  defmacro reversed(first, second) do
    quote do
      unquote(second)
      unquote(first)
    end
  end

  defmacro unpack(pattern, value) do
    quote do
      destructure(unquote(pattern), unquote(value))
    end
  end
end
