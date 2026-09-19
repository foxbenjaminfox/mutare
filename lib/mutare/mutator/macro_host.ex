defmodule Mutare.Mutator.MacroHost do
  @moduledoc """
  Capability behaviour for a mutator that hosts mutations inside a compile-time DSL.

  Ordinary mutators operate on runtime Elixir expressions. A fragment inside a macro such as Ecto's `where` has the library's own semantics and cannot necessarily contain Mutare's ordinary selector. A macro host inserts selectors in the form that DSL accepts.

  Macro registration and argument routing belong to the independent `Mutare.CallRouting` capability. A host subscribes to the macros it can mutate through `c:hosted_macros/0`; a separate library extension may define their routing. This lets several independent mutators target the same DSL without replacing one another.

  `host/2` is itself a mutation-producing callback, so a mutator that delivers all of its mutations through the DSL needs no `mutate/1` — just `name/0` to identify it in reports:

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

  (Add a `mutate/1` only if the mutator *also* mutates whole nodes outside the DSL.) See `Mutare.CallRouting` for the "which behaviours do I implement?" table. The same module may also implement `Mutare.CallRouting` when it provides both the DSL adapter and its mutations, but the capabilities remain independently composable.
  """

  @typedoc "A macro selector returned by `c:hosted_macros/0`."
  @type macro_selector ::
          {module :: atom(), name :: atom()}
          | {module :: atom(), name :: atom(), arity :: non_neg_integer() | :any}

  @doc """
  Declare the macros this host can mutate.

  Selectors contain identity only, not argument treatments. The merged `Mutare.CallRouting`
  declaration remains the sole source of routing semantics. Wildcards follow `call_routes/0`:
  `:*` may occupy the module or name slot, and omitted arity means `:any`.
  """
  @callback hosted_macros() :: [macro_selector()]

  @doc """
  Produces mutations for fragments inside a compile-time DSL.

  The transform passes the callback a resolved `Mutare.CallRouting.Call` and expects a list of
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

  The callback defines the DSL-specific mutations and selector placement.
  Core assigns ids, records sites and coverage, and assembles selectors, so survivor diffs contain
  only the logical fragment change.

  Subscribe through `c:hosted_macros/0`. The active macro route must contain `:hosted`, either
  statically or from `c:Mutare.CallRouting.route_arguments/1`. `context` is the same map
  `c:Mutare.Mutator.mutate/2` receives, plus `:mutators` — the run's enabled
  `Mutare.Mutator.Spec`s (hosts included; `Mutare.Analyze.expression_mutations/3` lowers a
  nested host's targets to whole-call rebuilds instead of weaving them, so a sub-contracted
  island analyzes with every surface — ordinary and hosted — and hosted delivery never nests).

  A `:hosted` route is permission and a delivery mode, **not a target list**: the callback
  receives the whole resolved macro call and locates the fragment(s) to mutate. It
  need not re-classify the call to do so — `Mutare.Calls.routed_treatments/1` on the
  call's `node` returns the per-argument treatments the route produced, so the `:hosted`
  positions (including values nested under `{:keyword, …}`) can be read back instead of
  rediscovered. Core leaves hosted fragments raw and does not route nested macros inside them;
  the same function provides routing information for nested macros traversed by the host.

  ## Sub-contracting ordinary Elixir inside a fragment

  A hosted fragment may contain ordinary Elixir expressions: everything under an Ecto `^` pin
  is evaluated at runtime. Use core's value mutations for those expressions through
  `Mutare.Analyze.expression_mutations(island, context.mutators, context)`. It returns each
  single-point mutant as a rebuild of the expression, produced by the user's actual
  configuration. Relay each rebuild as a `Mutare.Mutator.Mutation` with `producer:` set to the
  returned spec — the host then embeds the mutant, while its
  site and `# mutare:ignore` labels refer to the producing core family.
  """
  @callback host(
              call :: Mutare.CallRouting.Call.t(),
              context :: Mutare.Mutator.context()
            ) :: [Mutare.Mutator.MacroHost.Target.t()]
end
