defmodule Mutare.Mutator.MacroHost do
  @moduledoc """
  Capability behaviour for a mutator that hosts mutations inside a compile-time DSL.

  Ordinary mutators see runtime Elixir expressions. A fragment inside a macro such
  as Ecto's `where` has the library's own semantics and cannot necessarily contain
  Mutare's ordinary selector. A macro host inserts selectors in the form that DSL
  accepts.

  Macro registration and argument routing belong to the independent `Mutare.MacroRouting`
  capability. A host subscribes to the macros it can mutate through `c:hosted_macros/0`; a
  separate library extension may own their routing. This lets several independent mutators target
  the same DSL without replacing one another.

  `host/2` is itself a mutation-producing callback, so a mutator that delivers **all** of its
  mutations through the DSL needs no `mutate/1` — just `name/0` to identify it in reports:

      defmodule MyApp.Mutators.Ecto do
        alias Mutare.Mutator.MacroHost.Target

        @behaviour Mutare.Mutator
        @behaviour Mutare.Mutator.MacroHost

        @impl Mutare.Mutator
        def name, do: :ecto_query

        @impl Mutare.Mutator.MacroHost
        def hosted_macros, do: [{Ecto.Query, :where, :any}]

        @impl Mutare.Mutator.MacroHost
        def host(call, context) do
          [Target.new(fragment, mutations, &splice/2)]
        end
      end

  (Add a `mutate/1` only if the mutator *also* mutates whole nodes outside the DSL.) See
  `Mutare.MacroRouting` for the "which behaviours do I implement?" table.
  The same module may also implement `Mutare.MacroRouting` when it owns the DSL adapter as well as
  its mutations, but the capabilities remain independently composable.
  """

  @typedoc "A macro selector returned by `c:hosted_macros/0`."
  @type macro_selector ::
          {module :: atom(), name :: atom()}
          | {module :: atom(), name :: atom(), arity :: non_neg_integer() | :any}

  @doc """
  Declare the macros this host can mutate.

  Selectors contain identity only, not argument treatments. The merged `Mutare.MacroRouting`
  declaration remains the sole source of routing semantics. Wildcards follow `macro_routes/0`:
  `:*` may occupy the module or name slot, and omitted arity means `:any`.
  """
  @callback hosted_macros() :: [macro_selector()]

  @doc """
  Produces mutations for fragments inside a compile-time DSL.

  The transform hands the callback a resolved `Mutare.MacroRouting.Call` and expects a list of
  `Mutare.Mutator.MacroHost.Target` values, one per fragment to mutate. A target carries:

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

  Subscribe through `c:hosted_macros/0`. The active macro route must contain `:hosted`, either
  statically or from `c:Mutare.MacroRouting.route_arguments/2`. `context` is the same map
  `c:Mutare.Mutator.mutate/2` receives, plus `:mutators` — the run's enabled non-host
  `Mutare.Mutator.Spec`s.

  A `:hosted` route is permission and a delivery mode, **not a target list**: the callback
  receives the whole resolved macro call and owns locating the fragment(s) it will mutate. It
  need not re-classify the call to do so — `Mutare.Calls.macro_treatment/1` on the
  call's `node` returns the per-argument treatments the route produced, so the `:hosted`
  positions (including values nested under `{:keyword, …}`) can be read back instead of
  rediscovered. Core leaves hosted fragments raw and does not route nested macros inside them;
  the same reader answers for a nested macro the host walks into.

  ## Sub-contracting ordinary Elixir inside a fragment

  A hosted fragment may contain islands of ordinary Elixir that are core's business, not the
  DSL's — everything under an Ecto `^` pin is evaluated at runtime. Rather than mirroring
  core's value conventions (or applying DSL semantics to non-DSL code), hand the island back to
  core's generation: `Mutare.Analyze.expression_mutations(island, context.mutators, context)`
  returns each single-point mutant as a rebuild of the island, produced by the user's actual
  configuration. Relay each rebuild as a `Mutare.Mutator.Mutation` with `producer:` set to the
  returned spec — the mutant then rides this host's weave (delivery stays host-owned) while its
  site and `# mutare:ignore` vocabulary belong to the producing core family.
  """
  @callback host(
              call :: Mutare.MacroRouting.Call.t(),
              context :: Mutare.Mutator.context()
            ) :: [Mutare.Mutator.MacroHost.Target.t()]
end
