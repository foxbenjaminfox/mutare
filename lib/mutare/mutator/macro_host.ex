defmodule Mutare.Mutator.MacroHost do
  @moduledoc """
  Capability behaviour for a mutator that hosts mutations inside a compile-time DSL.

  Ordinary mutators see runtime Elixir expressions. A fragment inside a macro such
  as Ecto's `where` has the library's own semantics and cannot necessarily contain
  Mutare's ordinary selector. A macro host inserts selectors in the form that DSL
  accepts.

  Macro registration and all argument routing belong to the independent
  `Mutare.MacroRouting` capability. A hosting mutator implements both behaviours, registers a
  `:hosted` treatment (or a `:routing` classifier that may return one) from
  `c:Mutare.MacroRouting.macro_routes/0`, and supplies the hosted mutations here.

  `host/2` is itself a mutation-producing callback, so a mutator that delivers **all** of its
  mutations through the DSL needs no `mutate/1` — just `name/0` to identify it in reports:

      defmodule MyApp.Mutators.Ecto do
        @behaviour Mutare.Mutator
        @behaviour Mutare.MacroRouting
        @behaviour Mutare.Mutator.MacroHost

        @impl Mutare.Mutator
        def name, do: :ecto_query

        @impl Mutare.MacroRouting
        def macro_routes, do: [{Ecto.Query, :where, :any, :routing}]

        @impl Mutare.MacroRouting
        def macro_routing(call, _context), do: ...

        @impl Mutare.Mutator.MacroHost
        def host(call, context), do: ...
      end

  (Add a `mutate/1` only if the mutator *also* mutates whole nodes outside the DSL.) See
  `Mutare.MacroRouting` for the "which behaviours do I implement?" table.
  `test/support/host_mutator.ex` contains working examples.
  """

  @doc """
  Produces mutations for fragments inside a compile-time DSL.

  The callback receives the whole macro node and returns one target map per
  fragment to mutate:

    * `:original` — the fragment before mutation, used for the baseline and the left side of the
      reported diff;
    * `:mutants` — mutated fragments, `%Mutare.Mutator.Mutation{}` values carrying report metadata,
      with inapplicable entries filtered out before returning the list. A top-level bare `nil`
      entry is rejected; use `Mutare.AST.literal(nil)` for a literal-`nil` replacement;
    * `:splice` — a 2-arity `(macro_node, case_node -> macro_node)` function that inserts the
      assembled selector into a copy of the macro node;
    * `:wrap` — optional 1-arity `(fragment -> node)` function mapping each fragment to its branch
      value, such as `&dynamic([u], &1)`; defaults to identity;
    * `:range` — optional `Sourceror.Range.t()` used for the site; defaults to the original
      fragment's range.

  The callback owns the DSL-specific mutation semantics and selector placement.
  Core owns ids, sites, coverage, and selector assembly, so survivor diffs contain
  only the logical fragment change.

  Register the macro and its `:hosted` treatment through
  `c:Mutare.MacroRouting.macro_routes/0`. For shape-dependent hosting, register `:routing` and
  return `:hosted` from `c:Mutare.MacroRouting.macro_routing/2` for the applicable call shapes.
  `context` is the same map `c:Mutare.Mutator.mutate/2` receives.

  Core leaves hosted fragments raw and does not route nested macros inside them. A
  host that walks the fragment can read nested macro routing with
  `Mutare.Transform.Calls.macro_treatment/1`.
  """
  @callback host(macro_node :: Macro.t(), context :: Mutare.Mutator.context()) :: [map()]
end
