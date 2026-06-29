defmodule Mutare.Mutator.MacroHost do
  @moduledoc """
  Capability behaviour for a mutator that hosts mutations inside a compile-time DSL.

  Ordinary mutators see runtime Elixir expressions. A fragment inside a macro such as Ecto's
  `where` has the library's semantics and cannot contain Mutare's ordinary selector directly.
  A macro host weaves selectors into that DSL through `c:host/2`.

  Macro registration and all argument routing belong to the independent
  `Mutare.MacroRouting` capability. A hosting mutator implements both behaviours, registers a
  `:hosted` treatment (or a `:routing` classifier that may return one) from
  `c:Mutare.MacroRouting.macro_routes/0`, and supplies the hosted mutations here.

      defmodule MyApp.Mutators.Ecto do
        @behaviour Mutare.Mutator
        @behaviour Mutare.MacroRouting
        @behaviour Mutare.Mutator.MacroHost

        @impl Mutare.Mutator
        def name, do: :ecto_query
        @impl Mutare.Mutator
        def mutate(node), do: ...

        @impl Mutare.MacroRouting
        def macro_routes, do: [{Ecto.Query, :where, :any, :routing}]

        @impl Mutare.MacroRouting
        def macro_routing(call), do: ...

        @impl Mutare.Mutator.MacroHost
        def host(call, context), do: ...
      end

  `test/support/host_mutator.ex` contains working examples.
  """

  @doc """
  Produce mutations for fragments inside a compile-time DSL.

  The transform hands the callback the **whole macro node** and expects a list of targets, one per
  fragment to mutate. Each target is a map:

    * `:original` — the fragment before mutation, used for the baseline and the left side of the
      reported diff;
    * `:mutants` — mutated fragments, `%Mutare.Mutator.Mutation{}` values carrying report metadata,
      or `nil` entries to drop;
    * `:splice` — a 2-arity `(macro_node, case_node -> macro_node)` function that weaves the
      assembled selector into a copy of the macro node;
    * `:wrap` — optional 1-arity `(fragment -> node)` function mapping each fragment to its branch
      value, such as `&dynamic([u], &1)`; defaults to identity;
    * `:range` — optional `Sourceror.Range.t()` used for the site; defaults to the original
      fragment's range.

  The callback owns the foreign DSL's mutation semantics and selector placement. Core owns ids,
  sites, coverage, and selector assembly, so survivor diffs contain only the logical fragment swap.

  Register the macro and its `:hosted` treatment through
  `c:Mutare.MacroRouting.macro_routes/0`. For shape-dependent hosting, register `:routing` and
  return `:hosted` from `c:Mutare.MacroRouting.macro_routing/1` for the applicable call shapes.
  `context` is the same map `c:Mutare.Mutator.mutate/2` receives.

  Core leaves a hosted fragment raw and does not route nested macros inside it. A host walking the
  fragment can read their resolved routing with `Mutare.Transform.Calls.macro_treatment/1`.
  """
  @callback host(macro_node :: Macro.t(), context :: Mutare.Mutator.context()) :: [map()]
end
