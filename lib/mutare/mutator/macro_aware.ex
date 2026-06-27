defmodule Mutare.Mutator.MacroAware do
  @moduledoc """
  Behaviour for a **macro-aware mutator** — one that targets a *macro* whose arguments the
  transform must route specially (a pattern, an opaque DSL body, or a fragment hosted inside a
  compile-time DSL) before the mutator can act on it.

  Ordinary mutators see runtime expressions. A macro can wrap its arguments in a *pattern* position
  (`match?`), an opaque compile-time DSL (`Ecto.Query.from`), or a fragment with foreign semantics
  core can't vouch for (`Ecto`'s `where`). A macro-aware mutator teaches the transform how to treat
  those arguments via `c:macros/0` (and, for routing that depends on the call *shape*,
  `c:macro_routing/1`), and — for the deep hosted case — delivers its mutations through `c:host/2`.
  Registration is automatic: listing the mutator under `:mutators` merges its `c:macros/0` into the
  known-macro registry (`Mutare.Macros`), so a library ships *one* module carrying both its mutator
  and the macro routing it relies on, and the user adds a single `:mutators` entry. Core never has
  to know about the library.

  This is the mutator-side counterpart to `Mutare.Plugin`'s `c:Mutare.Plugin.macros/0`: a *plugin*
  registers routing **without** producing mutations; a macro-aware *mutator* registers routing
  **because** it also mutates the macro. (No built-in mutator is macro-aware — the built-in
  `Kernel.match?`/`destructure` routings live in `Mutare.Macros` itself.)

  A macro-aware mutator is still a `Mutare.Mutator` (it needs `name/0` and a mutation producer);
  declare **both**:

      defmodule Mutare.Ecto do
        @behaviour Mutare.Mutator
        @behaviour Mutare.Mutator.MacroAware

        @impl Mutare.Mutator
        def name, do: :ecto_query
        @impl Mutare.Mutator
        def mutate(node), do: ...                       # drop a where, flip :asc/:desc

        @impl Mutare.Mutator.MacroAware
        def macros, do: [{Ecto.Query, :from, :any, :skip}]
      end

  `test/support/macro_mutator.ex` and `test/support/host_mutator.ex` are working examples.

  ## Registering known macros (`macros/0`)

  Returns a list of `Mutare.Macro.Spec` entries in the declarative form
  `{module, name, arity, treatment}` or `{module, name, treatment}` (arity `:any`), where
  `treatment` is one of `:expression` / `:pattern` / `:binding_pattern` / `:skip` / `:hosted`
  (uniform), a per-position list, or the `:routing` classifier sentinel (deferring to
  `c:macro_routing/1`). `module`/`name` may be the wildcard `:*` — `{module, :*, treatment}`
  registers a whole module, `{:*, name, treatment}` a name in any module (see `Mutare.Macro.Spec`).
  A `:hosted` argument is delivered through this module's `c:host/2` (the deep `Ecto.from`/`where`
  case); a `:routing` spec lets the treatment depend on the call shape.

  The whole macro node is still offered to the mutator's `c:Mutare.Mutator.mutate/1` regardless of
  treatment (`:skip` only stops core descending into the args), so the registering mutator fires.
  `Mutare.Macros.from_mutators/1` discovers implementers by `function_exported?(mod, :macros, 0)`.

  ## Shape-aware routing (`macro_routing/1`)

  A static per-position treatment list in `c:macros/0` can't express a routing that depends on the
  call *shape*. Register the macro `:routing` and implement `c:macro_routing/1` to classify each
  concrete call.

  ## Selector hosting (`host/2`)

  For a fragment *inside* a compile-time DSL — a `:hosted` argument, where core can neither splice a
  bare selector `case` (it would poison the single build) nor vouch for the fragment's semantics —
  the mutator owns the mutation logic and hands core the per-fragment `:original` / `:mutants` /
  `:wrap` / `:splice` targets; core builds the id-gated selector, records the `Mutare.Site`s, and
  weaves it in. See `c:host/2` and `Mutare.Transform.HostedEmit.emit/5`.
  """

  @doc """
  Optional hook by which a mutator registers the **known macros** it depends on —
  macros whose arguments the transform must route specially (a pattern argument, an
  opaque DSL body) for this mutator to work, or simply to keep core from mutating a
  DSL it does not understand.

  Returns a list of `Mutare.Macro.Spec` entries in the declarative form
  `{module, name, arity, treatment}` or `{module, name, treatment}` (arity `:any`),
  where `treatment` is one of `:expression` / `:pattern` / `:binding_pattern` / `:skip` /
  `:hosted` (uniform), a per-position list, or the `:routing` classifier sentinel (deferring
  to `c:macro_routing/1`). `module`/`name` may be the wildcard `:*` — `{module, :*, treatment}`
  registers a whole module, `{:*, name, treatment}` a name in any module (see `Mutare.Macro.Spec`).
  A `:hosted` argument is delivered through this module's `c:host/2`
  (the deep `Ecto.from`/`where` case); a `:routing` spec lets the treatment depend on the call
  shape. When the mutator is enabled (listed in `:mutators`), the
  transform merges these into its macro registry automatically — so a library ships one module
  carrying *both* its mutator and the registration it relies on, and the
  user adds a single `:mutators` entry. Core never has to know about the library.

  The motivating case: an Ecto integration registers `{Ecto.Query, :from, :any,
  :skip}` so core leaves the query DSL untouched, while the same module's
  `c:Mutare.Mutator.mutate/1` rewrites the query (drop a `where`, flip `:asc`/`:desc`).
  `Mutare.Macros.from_mutators/1` discovers implementers by
  `function_exported?(mod, :macros, 0)`; a mutator without it registers nothing.
  """
  @callback macros() :: [tuple()]

  @doc """
  Optional **selector host** for mutating a fragment *inside* a compile-time DSL — a
  `:hosted` macro argument (see `Mutare.Macro.Spec`). The deep external-DSL case
  (`Ecto`'s `from`/`where`), where core can neither splice a bare selector `case` (it
  would poison the single build) nor vouch for the fragment's semantics. So core owns
  none of the mutation logic: it hands the **whole macro node** to this callback, which
  returns a list of *targets* — one per fragment to mutate — and core builds the id-gated
  selector, records the Sites, and weaves it in.

  Each target is a map:

    * `:original` — the logical fragment before mutation (the Site diff's left side, and
      what the wrapped catch-all baseline runs);
    * `:mutants` — the list of logical mutated fragments (one mutant id + `Mutare.Site` each),
      from the library's *own* semantics catalog (e.g. SQL's, **not** core's Elixir mutators).
      Each entry is a bare fragment node, a `%Mutare.Mutator.Mutation{}` (a `node` + a `note`
      recorded on that mutant's Site for the report, e.g. "kill may require NULL/boundary data"),
      or `nil` (dropped) — the same `t:Mutare.Mutator.mutation/0` forms `mutate/1`/`mutate/2`
      accept;
    * `:splice` — a 2-arity `(macro_node, case_node -> macro_node)` weaving the assembled
      selector `case` into a copy of the (emitted) macro node (for Ecto, `^`-pinning it into
      the `where:` position);
    * `:wrap` — optional 1-arity `(fragment -> woven_node)` mapping each logical fragment to
      its branch value (`&dynamic([u], &1)`); defaults to identity;
    * `:range` — optional `Sourceror.Range.t()` for the Site; defaults to the `:original`'s.

  Core builds, per target, `case <id-selector> do <id> -> wrap(mutant); … ; <var> -> <cov>;
  wrap(original) end`, splices it with `:splice`, assigns the ids, and records each mutant as
  an `:in_place` `Mutare.Site` showing the logical fragment swap (the `wrap`/`splice`
  scaffolding invisible). The single rule that keeps this sound: *the mutator hands core
  `wrap`/`splice` and lets core build the selector* — so the four cross-cutting contracts
  (compile-once, contiguous poison-stable ids, coverage, poison line-mapping) stay in core.

  Registered by a `:hosted` (or `:routing`-classified) treatment in `c:macros/0`; the
  transform discovers it by `function_exported?(mod, :host, 2)`. `context` is the same map
  as `c:Mutare.Mutator.mutate/2`'s (`:pipe_mode`/`:opts`/`:behaviours`).
  """
  @callback host(macro_node :: Macro.t(), context :: Mutare.Mutator.context()) :: [map()]

  @doc """
  Optional **shape-aware routing** classifier for a macro registered `:routing` in
  `c:macros/0`. A static per-position treatment list can't express a routing that depends
  on the call *shape* — `where(q, category: "Foo")` is plain data (`:expression`) while
  `where(q, [u], u.x == u.y)` is a `:hosted` DSL fragment. The transform calls
  this with the concrete call node and uses the returned per-position treatment list (for the
  node's **visible** arguments) instead of a fixed one. Each element is a
  `t:Mutare.Macro.Spec.treatment/0` (`:expression`/`:pattern`/`:binding_pattern`/`:skip`/
  `:hosted`); a `:hosted` here is delivered through this same mutator's `c:host/2`.

  The list covers only the call's **visible** arguments. For a **piped** call (`q |> where(c)`)
  the piped value is the `|>` LHS — *not* a visible argument and never routed here (it stays an
  ordinary `:expression`), so a piped call passes one fewer argument than the written form. A
  classifier that matches on arity must handle that reduced shape (match the visible args, not a
  fixed count). The returned treatments are validated by the transform: an
  unrecognised or mis-shaped treatment raises rather than silently mutating a position you meant
  to skip or host.

  ## Per-keyword-pair routing — `{:keyword, value_treatments}`

  Besides the static treatments, the classifier may return two **classifier-only** routing
  values (a static `args` can't carry them):

    * `{:keyword, value_treatments}` for a **keyword-list argument**, a routing the per-argument
      granularity can't otherwise reach. Core routes each `key: value` pair's **value** by the
      corresponding treatment in `value_treatments` (positional; a value past the list defaults
      to `:skip`) and leaves every **key** raw — a keyword key in a DSL is a field/option *name*,
      not a value to mutate. A value treatment may itself be `{:keyword, …}`, so a *nested*
      keyword list (a list whose values are keyword lists) routes too. A non-keyword argument
      under it falls back to raw, so a mis-shaped classification can never splice into a non-pair.
      A keyword value is a `t:keyword_value_treatment/0`. A nested `:hosted` value is left raw by
      core and delivered through this module's `c:host/2`, which still receives and weaves into the
      whole macro node.

    * `:pinned` for a **value that must be `^`-pinned** — it sits in a compile-time DSL position
      (an Ecto keyword-shorthand value) that accepts an interpolated value but not a bare
      selector `case`. Core mutates it with the configured literal families (their *own* names on
      the Site — the value mutation stays core's), but wraps the selector in `^`. Use it as a
      value treatment inside `{:keyword, …}`, for a **scalar** value only (a compound value would
      mutate nested nodes, where an inner `^` still poisons). A bare `^` is a compile error
      outside such a context, so only route a position `:pinned` when the macro genuinely
      interpolates it.

  The motivating case is Ecto's keyword-shorthand `where(q, category: "Foo", deleted_at: nil)`:
  `{:keyword, [:pinned, :skip]}` — mutate `"Foo"` `^`-pinned (core's literal families), the
  column-name keys raw, and the `deleted_at: nil` pair skipped (it compiles to `IS NULL`).
  """
  @callback macro_routing(call_node :: Macro.t()) :: [routing_treatment()]

  @typedoc """
  A treatment a `c:macro_routing/1` classifier may return for one **visible argument**: a static
  `t:Mutare.Macro.Spec.treatment/0` (`:expression`/`:pattern`/`:binding_pattern`/`:skip`/`:hosted`)
  plus the two **classifier-only** routings a fixed `args` can't carry — `:pinned` (mutate the
  value but deliver the selector `^`-pinned) and `{:keyword, [keyword_value_treatment]}` (route each
  keyword pair's value, keys raw). The `{:keyword, …}` arm is **recursive**: a value treatment may
  itself be `{:keyword, …}`, so a nested keyword shorthand (`from(S, where: [x: v])`) routes too.

  A keyword *value* is a `t:keyword_value_treatment/0`. A nested `:hosted` treatment leaves that
  value raw during core descent and asks the registering mutator's `c:host/2` to weave selectors
  into the whole macro node.
  """
  @type routing_treatment ::
          Mutare.Macro.Spec.treatment()
          | :pinned
          | {:keyword, [keyword_value_treatment()]}

  @typedoc """
  A treatment for a **value inside a `{:keyword, …}` routing**. A value may itself be
  `{:keyword, …}`, so a nested keyword shorthand routes too.
  """
  @type keyword_value_treatment ::
          :expression
          | :pattern
          | :binding_pattern
          | :skip
          | :hosted
          | :pinned
          | {:keyword, [keyword_value_treatment()]}

  @optional_callbacks macros: 0, host: 2, macro_routing: 1
end
