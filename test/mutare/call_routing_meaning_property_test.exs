defmodule Mutare.CallRouting.MeaningPropertyTest do
  @moduledoc """
  Property pins for what a configured `:skip` *means* (`Mutare.CallRouting.Registry.meaning/4`;
  NOTES "A skip's meaning is one registry lookup, wherever the call is read from"):

    * **A configured skip means the skipless route.** Where a configured `:skip` wins the
      cascade for a concrete call, its meaning is the route the *same* registry built with
      every configured skip left out selects for that call — the skip itself where that is
      nothing (the ordinary call it leaves). Every other call means the route it is routed by.
    * **Adding a configured skip never loses a declaration.** It changes a call's meaning only
      to the added skip, and only where the call meant nothing or a skip.

  Both are stated over the registry alone: generated code declarations (served through
  `Mutare.Test.GeneratedRoutes`, by one provider, the other, or both), generated configured
  routes, and every concrete call of the vocabulary. Providers never disagree with each other —
  a disagreement is a contract error wherever no configured entry settles it, so the one shape
  it can take (`:unknown` beneath a skip) is pinned by `call_routing_registry_test.exs`.

  Pure and fast (no source, no transform), so it runs in the normal async suite rather than
  under `:property`.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.CallRouting.Registry
  alias Mutare.CallRouting.Registry.Entry
  alias Mutare.CallRouting.Spec
  alias Mutare.Test.GeneratedRoutes

  @numtests 200

  # --- vocabulary -------------------------------------------------------------
  #
  # Small on purpose: keys must collide and cascade over each other for a skip to shadow
  # anything. `[:Kernel]` × `match?`/`destructure` reach the built-in declarations.
  @modules [[:A], [:A, :B], :erl, [:Kernel]]
  @names [:f, :g, :match?, :destructure]
  @arities [0, 1, 2, 3]
  @positions [:raw, :expression, :lazy_expression, :interior, :pattern, :binding_pattern]

  @calls for m <- @modules, n <- @names, a <- @arities, do: {m, n, a}

  # --- generators ---------------------------------------------------------------

  # Every valid key shape (`Spec.new/4`): exact, any-arity, module-wide, name-only.
  defp key do
    oneof([
      {oneof(@modules), oneof(@names), oneof(@arities ++ [:any])},
      {oneof(@modules), :*, :any},
      {:*, oneof(@names), oneof(@arities ++ [:any])}
    ])
  end

  # A positional treatment a configuration may declare (no classifier, no adapter grade).
  defp positional, do: oneof([oneof(@positions), non_empty(list(oneof(@positions)))])

  # A code provider's declaration may itself be a whole-call `:skip`; that is not a
  # *configured* skip, and the property must not read it as one.
  defp code_treatment, do: frequency([{1, :skip}, {3, positional()}])
  defp config_treatment, do: frequency([{2, :skip}, {1, positional()}])

  # A table of declarations, one treatment per key — a conflict-free registry input.
  defp table(treatment) do
    let entries <- list({key(), treatment}) do
      Enum.uniq_by(entries, fn {key, _} -> key end)
    end
  end

  # Code declarations, each made by provider A, provider B, or both. The built-in keys are
  # always declared already, so a generated provider may not redeclare them (a disagreement
  # is a contract error); a *configured* route may still override or shadow them.
  @builtin_keys Enum.map(Registry.builtin(), &Entry.key/1)

  defp code_routes do
    let entries <- table(code_treatment()) do
      for {key, treatment} <- entries, key not in @builtin_keys do
        {key, treatment, oneof([[:a], [:b], [:a, :b]])}
      end
    end
  end

  defp config_routes, do: table(config_treatment())

  # --- building -----------------------------------------------------------------

  defp route({{m, n, a}, treatment}), do: {m, n, a, treatment}

  defp build(config, code) do
    [a, b] = GeneratedRoutes.providers()
    GeneratedRoutes.put(a, for({key, t, owners} <- code, :a in owners, do: route({key, t})))
    GeneratedRoutes.put(b, for({key, t, owners} <- code, :b in owners, do: route({key, t})))
    Registry.build(Enum.map(config, &route/1), [], [a, b])
  end

  defp skipless(config), do: Enum.reject(config, fn {_key, t} -> t == :skip end)

  defp lookup(registry, {m, n, a}), do: Registry.lookup(registry, m, n, a)
  defp meaning(registry, {m, n, a}), do: Registry.meaning(registry, m, n, a)

  defp configured_skip?(%Entry{spec: spec, sources: [:config]}), do: Spec.skip?(spec)
  defp configured_skip?(_), do: false

  defp route_spec(nil), do: nil
  defp route_spec(%Entry{spec: spec}), do: spec

  # --- properties ---------------------------------------------------------------

  property "a configured skip means the route the skipless registry selects; any other call " <>
             "means its route",
           numtests: @numtests do
    forall code <- code_routes() do
      forall config <- config_routes() do
        registry = build(config, code)
        skipless = build(skipless(config), code)

        Enum.all?(@calls, fn call ->
          expected =
            case lookup(registry, call) do
              %Entry{spec: skip} = entry ->
                if configured_skip?(entry),
                  do: route_spec(lookup(skipless, call)) || skip,
                  else: skip

              nil ->
                nil
            end

          meaning(registry, call) == expected
        end)
      end
    end
  end

  property "adding a configured skip changes a call's meaning only to itself, and only where " <>
             "the call meant nothing or a skip",
           numtests: @numtests do
    forall code <- code_routes() do
      forall config <- config_routes() do
        configured = MapSet.new(config, fn {key, _} -> key end)

        forall new_key <- such_that(k <- key(), when: not MapSet.member?(configured, k)) do
          before = build(config, code)
          after_ = build(config ++ [{new_key, :skip}], code)
          added = Spec.new(elem(new_key, 0), elem(new_key, 1), elem(new_key, 2), :skip)

          Enum.all?(@calls, fn call ->
            was = meaning(before, call)
            now = meaning(after_, call)

            # A code skip beneath the added one reads the same as the added skip meaning
            # itself, so "changed to the added skip" is asserted only where `was` is a skip.
            if route_spec(lookup(after_, call)) == added,
              do: now == was or (now == added and (was == nil or Spec.skip?(was))),
              else: now == was
          end)
        end
      end
    end
  end
end
