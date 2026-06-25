defmodule Mutare.Mutator do
  @moduledoc """
  Behaviour for mutators — pure functions over AST nodes.

  A mutator inspects a single AST node and returns either `:skip` (it does not
  apply here) or a list of mutated nodes, one per mutant to generate at that
  site. Mutators **never touch source text**; the transform locates the node,
  records its range, and splices the mutation in (a clean one-line diff).

  ## Writing one

  Match the node shapes you care about and rebuild them with the change,
  **reusing the original operand AST** so the mutation stays minimal:

      defmodule MyApp.Mutators.Boolean do
        @behaviour Mutare.Mutator

        @impl true
        def name, do: :boolean

        @impl true
        def mutate({:and, meta, [left, right]}), do: [{:or, meta, [left, right]}]
        def mutate({:or, meta, [left, right]}), do: [{:and, meta, [left, right]}]
        def mutate(_node), do: :skip
      end

  Two rules:

    * **Be compile-safe.** Every mutation lives in the *one* metamutant build, so
      a single mutation that won't compile sinks the whole run. Swapping one
      operator for another of the same kind always compiles; emitting an unbound
      variable does not.
    * **You don't choose placement.** Whether a mutation is delivered in place
      (a body expression) or by lifting (inside a `when` guard) is decided by
      *where the node sits*, not by the mutator. The same operator swap is used
      both ways.

  Build literal replacements with `Mutare.AST.literal/1` (it gets the Sourceror clean-meta
  rule right — a hand-built `{:__block__, [], ["x"]}` renders as the charlist `~c"x"`); see
  `Mutare.AST` for the sentinels and node predicates. To match aliased/imported stdlib calls,
  resolve with `Mutare.Transform.Calls.resolved_call/1`.

  ## Registering one

  List it under `:mutators` in `.mutare.exs` alongside (or instead of) the
  built-in family atoms — the value may be a built-in family atom or any module
  implementing this behaviour:

      [mutators: [:arithmetic, :relational, MyApp.Mutators.Boolean]]

  ## Configuring one (`{module, opts}`)

  To parametrize a mutator, give it `{module, opts}` instead of a bare module.
  `opts` reaches the mutator through the `context` of `mutate/2` as
  `context.opts` — so a configurable mutator implements `mutate/2`:

      defmodule MyApp.Mutators.MagicNumber do
        @behaviour Mutare.Mutator
        def name, do: :magic_number

        # A configurable mutator needs the `opts`, so it works through `mutate/2` and omits the
        # (optional) `mutate/1`.
        def mutate({:__block__, _m, [n]}, %{opts: opts}) when is_integer(n) do
          case Keyword.get(opts, :swaps, %{})[n] do
            nil -> :skip
            to -> [{:__block__, [], [to]}]
          end
        end

        def mutate(_node, _context), do: :skip
      end

      # .mutare.exs
      [mutators: [:arithmetic, {MyApp.Mutators.MagicNumber, swaps: %{200 => 500}}]]

  The reserved `:as` key in `opts` overrides the recorded family name (so the same
  module can run twice under distinct names); it is stripped before `opts` reaches
  the mutator. See `Mutare.Mutator.Spec`.

  Besides mutator-defined opts (read via `context.opts`, above), the **transform**
  recognises one positional opt directly from the spec — `call_option_keys: false`,
  which suppresses *this* mutator's mutations of a **call-option key** (a key of a
  keyword list passed as a call's final argument, `foo(x, timeout: 5)` → `timeout:`).
  It is positional — only the transform knows a node is a call-option key — so it can't
  be a `mutate/2` decision, but the *choice* is the mutator's, carried in its spec:

      # mutate option values but not the option names, for atom keys
      [mutators: [..., {Mutare.Mutators.AtomLiteral, call_option_keys: false}]]

  ## Registering known macros (`macros/0`)

  A mutator that targets a *macro* — whose arguments the transform must route as
  patterns or leave opaque — declares those macros with the optional `c:macros/0`
  callback. Listing the mutator in `:mutators` then auto-registers them, so a
  library (e.g. an Ecto integration) bundles its mutator and its macro routing in
  one module:

      defmodule Mutare.Ecto do
        @behaviour Mutare.Mutator
        def name, do: :ecto_query
        def mutate(node), do: ...                       # drop a where, flip :asc/:desc
        def macros, do: [{Ecto.Query, :from, :any, :skip}]
      end

  See `Mutare.Macros` for the declarative `:macros` option (the no-mutator case,
  e.g. routing a custom DSL's argument as a pattern).

  ## Registering a collection literal (`empty_collection?/1`)

  On the right of `in`, a mutant that empties a collection (`x in <empty>`) is
  constantly `false` — exactly what `Mutare.Mutators.Conditional` already produces on
  the `in` node — so the transform drops it as a redundant sibling. Core recognises the
  standard empty literals (`[]`, `%{}`, `~w()`, `~c""`). A mutator that collapses a
  *non-standard* collection — its own sigil (`~SET[]`), or a builder call
  (`MapSet.new([])`) — declares that with the optional `c:empty_collection?/1` callback,
  and earns the same suppression for its shape:

      defmodule MyApp.Mutators.Set do
        @behaviour Mutare.Mutator
        def name, do: :set
        def mutate({:sigil_SET, m, [{:<<>>, bm, [_]}, mods]}),
          do: [{:sigil_SET, m, [{:<<>>, bm, [""]}, mods]}]   # collapse ~SET[…] → ~SET[]
        def mutate(_), do: :skip
        def empty_collection?({:sigil_SET, _, [{:<<>>, _, [""]}, _]}), do: true
        def empty_collection?(_), do: false
      end

  The transform asks the mutator that *produced* the mutation, so the value is its own
  output; discovered by `function_exported?(mod, :empty_collection?, 1)`.

  ## Structural mutators at routed positions (`return_replacements/1` / `condition_replacements/1`)

  Some mutation targets are *positions* no single node identifies: a `def`/`defp` clause's
  **return tail**, or an `if`/`unless`/`cond` **condition**. For those, `mutate/1` is `:skip`
  and you implement the matching structural callback — `c:return_replacements/1` or
  `c:condition_replacements/1` — returning the replacement node(s). The transform names the
  position and asks *every* enabled mutator implementing the callback (via
  `Mutare.Mutator.implementing/3`), delivering each in place and recording it under its own
  name. `Mutare.Mutators.ReturnValue` / `Mutare.Mutators.IfCondition` are the built-ins; a
  custom mutator implementing the same callback participates identically — they are not
  hardcoded. (The head-pattern analog is `c:pattern_mutations/2`, delivered by lifting.)

  ## Behaviour-targeted mutators (`context.behaviours`)

  A mutator can fire differently — or only — inside modules that implement a given
  `@behaviour`. The enclosing module's behaviour set (a `MapSet` of module atoms, gathered
  from direct `@behaviour Foo` *and* `use`-injected ones like `use GenServer`, see
  `Mutare.Transform.Behaviours`) reaches a mutator under the context map's `:behaviours` key:

      defmodule MyApp.Mutators.GenServerReply do
        @behaviour Mutare.Mutator
        def name, do: :genserver_reply
        def mutate(_node), do: :skip

        # swap a `{:reply, r, s}` to `{:noreply, s}` only inside a GenServer
        def mutate({:{}, m, [{:__block__, am, [:reply]}, _r, state]}, %{behaviours: bs}) do
          if MapSet.member?(bs, GenServer),
            do: [{:{}, m, [{:__block__, am, [:noreply]}, state]}],
            else: :skip
        end

        def mutate(_node, _context), do: :skip
      end

  The structural callbacks have **behaviour-aware variants** carrying the same set in a
  `%{behaviours: …}` context: `c:return_replacements/2`, `c:condition_replacements/2`,
  `c:pattern_mutations/3`. Implement the `+1`-arity instead of the base to gate a return
  tail / condition / head pattern on the module's behaviours (e.g. a GenServer mutator that
  rewrites a `handle_call` return tail only under `@behaviour GenServer`); the transform
  prefers the context arity when exported. `test/support/behaviour_mutator.ex` is a working
  example covering both `mutate/2` and `return_replacements/2`.

  ## Matching aliased / imported calls (`Mutare.Transform.Calls`)

  A mutator that targets a stdlib/remote call should resolve the node with
  `Mutare.Transform.Calls.resolved_call/1` rather than pattern-matching the raw `Mod.fun(...)`:
  it returns `{module, fun, args, rebuild}` resolved through `alias`/`import`/Erlang-atom forms
  (or `nil`), so the mutator fires on `String.upcase`, `S.upcase`, and `import String; upcase`
  alike, and `rebuild` re-emits the swap in the form the source wrote. This is how the built-in
  call families reach aliased/imported calls; custom mutators get the same. See that module.
  """

  alias Mutare.AST
  alias Mutare.Mutator.Spec

  @typedoc """
  Context threaded to the optional `mutate/2` at each runtime call site. Carries:

    * `:pipe_mode` — `:piped` or `:unpiped` (see `t:pipe_mode/0`): whether the node is
      the right-hand side of a `|>` (so its effective first argument is the pipe's left
      side, *not* present in the node's own args). The transform builds this atom directly
      and a mutator passes it straight to `effective_arity/2` / `visible_index/2`.
    * `:opts` — the configured mutator's per-instance options (the `opts` of a
      `{module, opts}` entry in `:mutators`, with any `:as` name override
      stripped), or `[]` for an unconfigured mutator. This is how a configurable
      mutator receives its parameters — see `Mutare.Mutator.Spec`.
    * `:behaviours` — the enclosing module's behaviour set: a `MapSet` of the modules it
      implements via `@behaviour Foo` (directly or injected by a `use`, see
      `Mutare.Transform.Behaviours`). Empty outside a module. This is how a
      **behaviour-targeted** mutator gates itself — e.g. a GenServer mutator firing only
      when `MapSet.member?(context.behaviours, GenServer)`.

  `:opts` and `:behaviours` are `optional` in the type because the *base* context threaded
  through `mutations/3` carries only `:pipe_mode`; `mutations/3` injects each spec's `:opts`
  and `:behaviours` before invoking a mutator, so a callback always sees both at runtime.
  """
  @type context :: %{
          :pipe_mode => pipe_mode(),
          optional(:opts) => term(),
          optional(:behaviours) => MapSet.t(module())
        }

  @typedoc """
  Context threaded to the optional **structural** callbacks
  (`c:return_replacements/2`, `c:condition_replacements/2`, `c:pattern_mutations/3`).
  Carries the enclosing module's `:behaviours` set (a `MapSet` of module atoms), so a
  structural mutator can gate on the module's behaviours exactly as `mutate/2` does. (A
  structural position has no pipe context and structural mutators take no `opts`, so this
  is the lone key — the transform may add more in future.)
  """
  @type structural_context :: %{behaviours: MapSet.t(module())}

  @doc """
  Return `:skip` when the mutator does not apply to `node`, otherwise a list of
  mutated nodes (one per mutant).

  **Optional** — the entry point for a *node-level* mutator. A purely **structural** mutator
  (one driven by `pattern_mutations/2`, `return_replacements/1`, or `condition_replacements/1`)
  or a **pipe-aware/configurable** one (driven by `mutate/2`) produces no node-local mutation and
  simply omits this callback; `mutations/3` skips a mutator that doesn't export it. A module must
  still implement `name/0` plus at least one mutation-producing callback to count as a mutator.
  """
  @callback mutate(Macro.t()) :: :skip | [Macro.t()]

  @doc "Short family name, shown in reports (e.g. `:arithmetic`)."
  @callback name() :: atom()

  @doc """
  Optional **pipe-aware** variant of `mutate/1`, for mutations whose legality
  depends on a call's *effective arity* — which is ambiguous from the node alone,
  because Elixir expands `|>` only after this transform runs, so a pipe stage's
  node carries one fewer argument than the source reads.

  `Mutare.Transform` invokes it at every runtime call position with a `context`
  (`%{pipe_mode: pipe_mode, opts: term}`); a mutator passes `context.pipe_mode` to
  `effective_arity/2` to recover the effective arity. Used for arity-*changing* call mutations (dropping a refining
  argument, collapsing to a coarser call) that `mutate/1` cannot express safely —
  see `Mutare.Mutators.CollectionArity`. Discovered by
  `function_exported?(mod, :mutate, 2)`; a mutator without it takes no part.

  **`mutate/1` and `mutate/2` both run** (when both are exported) and their results are
  **combined** — `mutate/2` *augments*, never replaces, `mutate/1` (see `mutations/3`). So a
  mutator that *only* needs context returns `:skip` from `mutate/1` (`CollectionArity`,
  `ModeSwap`), while one that needs both keeps a real `mutate/1` and adds a `mutate/2` for the
  context-dependent part — `Mutare.Mutators.Arithmetic` swaps operators in `mutate/1` and
  `div`↔`rem` (pipe-aware) in `mutate/2`, the two firing on disjoint nodes. A custom mutator
  must therefore not duplicate a node-local mutation across both arities, or it is offered
  twice.

  This is also the callback a **configurable** mutator implements to read its
  options: `context.opts` carries the `opts` of its `{module, opts}` entry in
  `:mutators` (see `Mutare.Mutator.Spec`) — `mutate/1` has no context, so a mutator
  whose behaviour depends on its options matches its nodes here instead.
  """
  @callback mutate(Macro.t(), context()) :: :skip | [Macro.t()]

  @doc """
  Optional structural hook for mutating a `def`/`defp` clause **head pattern** as a
  whole — restructurings that `mutate/1` can't express because they span sibling
  positions or repeated variables (variable swaps, duplicate-variable wildcarding).

  Given a clause's head argument patterns and `used_outside` (the set of variable names
  read in the clause body/guard), it returns a list of mutated argument lists, one per
  mutant. `Mutare.Transform.FunctionPlan` discovers implementers by
  `function_exported?(mod, :pattern_mutations, 2)` and delivers each by lifting (a
  selector `case` is illegal in a pattern), so an implementer must return only
  *pattern-legal*, compile-safe argument lists. See `Mutare.Mutators.PatternSwap` and
  `Mutare.Mutators.PatternWildcard`. A mutator without this callback simply takes no
  part in head-pattern restructuring.
  """
  @callback pattern_mutations(head_args :: [Macro.t()], used_outside :: MapSet.t()) ::
              [[Macro.t()]]

  @doc """
  Behaviour-aware variant of `c:pattern_mutations/2`, taking the structural `context`
  (`%{behaviours: …}`). Implement *this* arity instead of `/2` to gate head-pattern
  mutations on the enclosing module's behaviours. The transform prefers `/3` when
  exported, falling back to `/2`; a mutator need implement only one.
  """
  @callback pattern_mutations(
              head_args :: [Macro.t()],
              used_outside :: MapSet.t(),
              context :: structural_context()
            ) :: [[Macro.t()]]

  @doc """
  Optional hook by which a mutator registers the **known macros** it depends on —
  macros whose arguments the transform must route specially (a pattern argument, an
  opaque DSL body) for this mutator to work, or simply to keep core from mutating a
  DSL it does not understand.

  Returns a list of `Mutare.Macro.Spec` entries in the declarative form
  `{module, name, arity, treatment}` or `{module, name, treatment}` (arity `:any`),
  where `treatment` is one of `:expression` / `:pattern` / `:binding_pattern` / `:skip` /
  `:hosted` (uniform), a per-position list, or the `:routing` classifier sentinel (deferring
  to `c:macro_routing/1`). A `:hosted` argument is delivered through this module's `c:host/2`
  (the deep `Ecto.from`/`where` case); a `:routing` spec lets the treatment depend on the call
  shape. When the mutator is enabled (listed in `:mutators`), the
  transform merges these into its macro registry automatically — so a library ships
  one module carrying *both* its mutator and the registration it relies on, and the
  user adds a single `:mutators` entry. Core never has to know about the library.

  The motivating case: an Ecto integration registers `{Ecto.Query, :from, :any,
  :skip}` so core leaves the query DSL untouched, while the same module's
  `mutate/1` rewrites the query (drop a `where`, flip `:asc`/`:desc`).
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
      Each entry is a bare fragment node, or a `%{node: fragment, note: string}` map to record an
      advisory on that mutant's Site for the report (e.g. "kill may require NULL/boundary data");
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
  as `c:mutate/2`'s (`:pipe_mode`/`:opts`/`:behaviours`).
  """
  @callback host(macro_node :: Macro.t(), context :: context()) :: [map()]

  @doc """
  Optional **shape-aware routing** classifier for a macro registered `:routing` in
  `c:macros/0`. A static per-position treatment list can't express a routing that depends
  on the call *shape* — `where(q, category: "Foo")` is plain data (`:expression`) while
  `where(q, [u], u.x == u.y)` is a `:hosted` DSL fragment. `Mutare.Transform.Resolve` calls
  this with the concrete call node and uses the returned per-position treatment list (for the
  node's **visible** arguments) instead of a fixed one. Each element is a
  `t:Mutare.Macro.Spec.treatment/0` (`:expression`/`:pattern`/`:binding_pattern`/`:skip`/
  `:hosted`); a `:hosted` here is delivered through this same mutator's `c:host/2`.

  The list covers only the call's **visible** arguments. For a **piped** call (`q |> where(c)`)
  the piped value is the `|>` LHS — *not* a visible argument and never routed here (it stays an
  ordinary `:expression`), so a piped call passes one fewer argument than the written form. A
  classifier that matches on arity must handle that reduced shape (match the visible args, not a
  fixed count). The returned treatments are validated by `Mutare.Transform.Resolve`: an
  unrecognised/mis-shaped treatment, or a `:hosted` inside a `{:keyword, …}` value, raises rather
  than silently mutating a position you meant to skip/host.

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
      A keyword value is a `t:keyword_value_treatment/0` — every treatment **except `:hosted`**:
      hosting weaves a selector into the *whole macro node* (`c:host/2`), and core has no
      per-keyword-value hosting delivery, so an individual value can't be hosted (route the whole
      argument `:hosted` instead). A `:hosted` nested in a `{:keyword, …}` is rejected at stamp
      time (`Mutare.Transform.Resolve`) rather than silently dropped or poisoned into the value.

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

  A keyword *value* is the narrower `t:keyword_value_treatment/0` — every treatment here **except
  `:hosted`**. Hosting weaves a selector into the *whole macro node* (`c:host/2`); core has no
  per-keyword-value hosting delivery, so an individual keyword value can't be hosted — route the
  whole argument `:hosted` instead. `Mutare.Transform.Resolve` rejects a `:hosted` nested in a
  `{:keyword, …}` at stamp time rather than silently dropping it or poisoning the DSL value.
  """
  @type routing_treatment ::
          Mutare.Macro.Spec.treatment()
          | :pinned
          | {:keyword, [keyword_value_treatment()]}

  @typedoc """
  A treatment for a **value inside a `{:keyword, …}` routing** — `t:routing_treatment/0` minus
  `:hosted` (a keyword value can't be hosted; see that type). A value may itself be `{:keyword, …}`,
  so a nested keyword shorthand routes too.
  """
  @type keyword_value_treatment ::
          :expression
          | :pattern
          | :binding_pattern
          | :skip
          | :pinned
          | {:keyword, [keyword_value_treatment()]}

  @doc """
  Optional hook by which a mutator declares that one of *its own* mutation results is
  an **empty enumerable literal** — a value `v` for which `x in v` is constantly
  `false`.

  On the right side of `in`, such a mutant is redundant: `Mutare.Mutators.Conditional`
  already forces the whole `x in …` to `false` on the `in` node, so `Mutare.Transform`
  drops it (see `Mutare.AST.empty_collection_literal?/1` and NOTES "Equivalent-sibling
  suppression"). Core recognises the *standard* empty literals itself — `[]`, `%{}`,
  `~w()`, `~c""` — so a mutator whose collapse produces one of those needs nothing. This
  callback is for a **non-standard** shape: a custom collection *sigil* (`~SET[]`), or a
  call/struct that builds an empty enumerable (`MapSet.new([])`). The transform asks the
  mutator that *produced* the mutation (its `mutated` node is the argument), so a library
  bundles this with its mutator like `c:macros/0`; discovered by
  `function_exported?(mod, :empty_collection?, 1)`.

  Returning `true` for a value where `x in v` is *not* always false would drop a real
  mutant (a recall loss, never a false kill) — so it must answer only for genuinely
  empty enumerables. A mutator without this callback simply takes no part.
  """
  @callback empty_collection?(mutated :: Macro.t()) :: boolean()

  @doc """
  Optional structural hook for mutating a **clause return tail** — the expression a
  `def`/`defp` clause (or a `rescue`/`catch`/`else` clause) returns. Given the raw tail
  node, return the replacement nodes (one per mutant), as clean-meta AST ready to splice.

  Like `c:pattern_mutations/2` this is *structural* — a return position is not a node any
  `mutate/1` could match, so the transform names the position and asks every enabled mutator
  implementing this callback (discovered by `function_exported?(mod, :return_replacements, 1)`),
  delivering each replacement by the in-place selector. `Mutare.Mutators.ReturnValue` is the
  built-in; a custom mutator implementing it participates at the same positions, its name
  recorded on the site. Return `[]` for a tail that should get no mutant.
  """
  @callback return_replacements(tail :: Macro.t()) :: [Macro.t()]

  @doc """
  Behaviour-aware variant of `c:return_replacements/1`, taking the structural `context`
  (`%{behaviours: …}`). Implement *this* arity instead of `/1` to gate return-tail
  mutations on the enclosing module's behaviours — the motivating GenServer case (swap a
  `handle_call` `{:reply, r, s}` tail to `{:noreply, s}` only when the module implements
  `GenServer`). The transform prefers `/2` when exported, falling back to `/1`.
  """
  @callback return_replacements(tail :: Macro.t(), context :: structural_context()) ::
              [Macro.t()]

  @doc """
  Optional structural hook for mutating an **`if`/`unless`/`cond` condition**. Given the raw
  condition node, return the replacement nodes (one per mutant). The condition-position twin
  of `c:return_replacements/1`: structural, discovered by
  `function_exported?(mod, :condition_replacements, 1)`, delivered in place.
  `Mutare.Mutators.IfCondition` is the built-in (forcing the condition `true`/`false`); a
  custom mutator implementing it participates at the same positions. Return `[]` to skip.
  """
  @callback condition_replacements(condition :: Macro.t()) :: [Macro.t()]

  @doc """
  Behaviour-aware variant of `c:condition_replacements/1`, taking the structural `context`
  (`%{behaviours: …}`). Implement *this* arity instead of `/1` to gate condition mutations
  on the enclosing module's behaviours. The transform prefers `/2` when exported, falling
  back to `/1`.
  """
  @callback condition_replacements(condition :: Macro.t(), context :: structural_context()) ::
              [Macro.t()]

  @optional_callbacks mutate: 1,
                      pattern_mutations: 2,
                      pattern_mutations: 3,
                      mutate: 2,
                      macros: 0,
                      host: 2,
                      macro_routing: 1,
                      empty_collection?: 1,
                      return_replacements: 1,
                      return_replacements: 2,
                      condition_replacements: 1,
                      condition_replacements: 2

  @typedoc """
  A call node's pipe context, as an atom: `:piped` (the node is a `|>` right-hand
  side, so its effective first argument is the pipe's left side) or `:unpiped`.
  Built directly by `Mutare.Transform` — it is what `Mutare.Transform.Resolve`'s
  `env.pipe_mode` and the `mutate/2` context's `:pipe_mode` carry — and the form
  `effective_arity/2` and `visible_index/2` take.
  """
  @type pipe_mode :: :piped | :unpiped

  @doc """
  The **effective arity** of a call node given its pipe context (`:piped`/`:unpiped`).

  A pipe stage (`x |> f(a)`) carries one fewer argument than the source reads: its
  effective first argument is the `|>` left side, which Elixir splices in only after
  this transform runs, so it is *not* in the node's own `args`. A pipe-aware mutator
  (`mutate/2`) recovers the real arity as `length(args)`, plus one when `:piped`.
  The single home for that off-by-one — see `Mutare.Mutators.CollectionArity` et al.

  The pipe context (`:piped`/`:unpiped`) comes straight from the `mutate/2` context's
  `:pipe_mode` key (`Mutare.Transform.Resolve`'s `env.pipe_mode`).

      iex> Mutare.Mutator.effective_arity([:a, :b], :unpiped)
      2
      iex> Mutare.Mutator.effective_arity([:b], :piped)
      2
  """
  @spec effective_arity([Macro.t()], pipe_mode()) :: non_neg_integer()
  def effective_arity(args, :piped) when is_list(args), do: length(args) + 1
  def effective_arity(args, :unpiped) when is_list(args), do: length(args)

  @doc """
  Map an **effective** argument index to the index into a call node's *visible*
  `args`, given pipe context (`:piped`/`:unpiped`) — the inverse of the
  `effective_arity/2` off-by-one.

  When piped, effective index `0` is the `|>` left side, which isn't in the
  node's own `args`, so it has no visible index (`nil`) and every later index
  shifts down by one. Unpiped, effective and visible indices coincide. The single
  home for that mapping — see `Mutare.Mutators.{ModeSwap,CollectionArity}`.

  The pipe context (`:piped`/`:unpiped`) comes straight from the `mutate/2` context's
  `:pipe_mode` key (`Mutare.Transform.Resolve`'s `env.pipe_mode`).

      iex> Mutare.Mutator.visible_index(2, :unpiped)
      2
      iex> Mutare.Mutator.visible_index(0, :piped)
      nil
      iex> Mutare.Mutator.visible_index(1, :piped)
      0
  """
  @spec visible_index(non_neg_integer(), pipe_mode()) :: non_neg_integer() | nil
  def visible_index(pos, :unpiped), do: pos
  def visible_index(0, :piped), do: nil
  def visible_index(pos, :piped), do: pos - 1

  @doc """
  The specs in `specs` whose module implements the optional callback `fun`/`arity`.

  The single home for "which enabled mutators opt into this structural hook", used for the
  position-routed structural callbacks (`return_replacements/1`, `condition_replacements/1`,
  `pattern_mutations/2`) — so the transform asks every implementer rather than hardcoding a
  built-in module.
  """
  @spec implementing([Spec.t()], atom(), arity()) :: [Spec.t()]
  def implementing(specs, fun, arity) do
    Enum.filter(specs, fn %{module: module} ->
      Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
    end)
  end

  @doc """
  The specs in `specs` whose module implements `fun` at **any** of `arities` — the
  any-arity variant of `implementing/3`, used to discover the structural hooks that come
  in a base form (`fun/n`) *and* a behaviour-aware form (`fun/(n+1)`, taking the structural
  context): a mutator implements one or the other. `return_replacements/{1,2}`,
  `condition_replacements/{1,2}`, `pattern_mutations/{2,3}`. The dispatch helpers
  (`return_replacements/2`, `condition_replacements/2`, `pattern_mutations/3` below) then
  call whichever arity each spec actually exports.
  """
  @spec implementing_any([Spec.t()], atom(), [arity()]) :: [Spec.t()]
  def implementing_any(specs, fun, arities) do
    Enum.filter(specs, fn %{module: module} ->
      Code.ensure_loaded?(module) and Enum.any?(arities, &function_exported?(module, fun, &1))
    end)
  end

  @doc """
  Run `spec`'s return-tail hook over `tail`, preferring the behaviour-aware
  `c:return_replacements/2` (passing the structural context) when the module exports it,
  else the base `c:return_replacements/1`. The single home for that arity dispatch, so the
  call sites stay one-liners and a mutator can implement either arity.
  """
  @spec return_replacements(Spec.t(), Macro.t()) :: [Macro.t()]
  def return_replacements(%Spec{module: module} = spec, tail) do
    if function_exported?(module, :return_replacements, 2),
      do: module.return_replacements(tail, structural_context(spec)),
      else: module.return_replacements(tail)
  end

  @doc """
  Run `spec`'s condition hook over `condition`, preferring `c:condition_replacements/2`
  (with the structural context) when exported, else `c:condition_replacements/1`. The
  condition-position twin of `return_replacements/2`.
  """
  @spec condition_replacements(Spec.t(), Macro.t()) :: [Macro.t()]
  def condition_replacements(%Spec{module: module} = spec, condition) do
    if function_exported?(module, :condition_replacements, 2),
      do: module.condition_replacements(condition, structural_context(spec)),
      else: module.condition_replacements(condition)
  end

  @doc """
  Run `spec`'s head-pattern hook over `head_args`/`used_outside`, preferring
  `c:pattern_mutations/3` (with the structural context) when exported, else
  `c:pattern_mutations/2`. The lifted-pattern twin of `return_replacements/2`.
  """
  @spec pattern_mutations(Spec.t(), [Macro.t()], MapSet.t()) :: [[Macro.t()]]
  def pattern_mutations(%Spec{module: module} = spec, head_args, used_outside) do
    if function_exported?(module, :pattern_mutations, 3),
      do: module.pattern_mutations(head_args, used_outside, structural_context(spec)),
      else: module.pattern_mutations(head_args, used_outside)
  end

  @doc """
  The **selector-host targets** `spec`'s mutator declares for the known-macro node `node`
  (`c:host/2`), normalized — each a map with `:original`, a list `:mutants`, a 2-arity
  `:splice`, a 1-arity `:wrap` (defaulted to identity), and an optional `:range`. `[]` when
  the module doesn't implement `host/2`. `context0` (`%{pipe_mode: …}`) is enriched with the
  spec's `:opts`/`:behaviours` before the callback runs, mirroring `mutations/3`.

  The single home for invoking a hosting mutator and validating its target shape, so
  `Mutare.Transform.Analyze` builds `Mutare.Transform.Candidate.Hosted`s without re-deriving
  the contract.
  """
  @spec host_targets(Spec.t(), Macro.t(), context()) :: [map()]
  def host_targets(%Spec{module: module, opts: opts, behaviours: behaviours}, node, context0) do
    if Code.ensure_loaded?(module) and function_exported?(module, :host, 2) do
      context = context0 |> Map.put(:opts, opts) |> Map.put(:behaviours, behaviours)
      module.host(node, context) |> Enum.map(&normalize_target/1)
    else
      []
    end
  end

  # Default `:wrap` to identity and `:range` to absent; require `:original`, a list `:mutants`,
  # and a 2-arity `:splice`. A malformed target raises (a library bug, not a target to silently
  # drop) — caught at transform time with the offending value. Each mutant is normalized to a
  # `{node, note}` pair: a bare node gets `note: nil`, a `%{node:, note:}` map carries an advisory
  # the report surfaces on the mutant's Site (e.g. "kill may require NULL/boundary data").
  defp normalize_target(%{original: original, mutants: mutants, splice: splice} = target)
       when is_list(mutants) and is_function(splice, 2) do
    %{
      original: original,
      mutants: Enum.map(mutants, &normalize_mutant/1),
      splice: splice,
      wrap: target_wrap(Map.get(target, :wrap)),
      range: Map.get(target, :range)
    }
  end

  defp normalize_target(other) do
    raise ArgumentError,
          "a host target must be a map with :original, a list :mutants and a 2-arity :splice " <>
            "(optional :wrap/:range), got: #{inspect(other)}"
  end

  # A host mutant is a bare node (no note) or a `%{node:, note:}` map (an advisory recorded on the
  # Site). The map form is unambiguous — a quoted AST node is never a bare map with these keys. A
  # `:note` that is neither a string nor nil is a library bug (the report renders it verbatim), so
  # raise rather than silently drop it — the same fail-loud stance as `normalize_target/1` above.
  defp normalize_mutant(%{node: node, note: note}) when is_binary(note) or is_nil(note),
    do: {node, note}

  defp normalize_mutant(%{node: _node, note: note}) do
    raise ArgumentError, "a host mutant :note must be a string or nil, got: #{inspect(note)}"
  end

  defp normalize_mutant(%{node: node}), do: {node, nil}
  defp normalize_mutant(node), do: {node, nil}

  defp target_wrap(nil), do: &Function.identity/1
  defp target_wrap(wrap) when is_function(wrap, 1), do: wrap

  defp target_wrap(other) do
    raise ArgumentError, "a host target :wrap must be a 1-arity function, got: #{inspect(other)}"
  end

  # The structural-callback context: the enclosing module's behaviour set, nothing else.
  defp structural_context(%Spec{behaviours: behaviours}), do: %{behaviours: behaviours}

  # The mutation-producing callbacks: a module is a mutator if it exports `name/0` *and* at least
  # one of these. `mutate/1` is no longer required — a structural/pipe-only family produces its
  # mutations through `mutate/2` or a structural hook instead. (`macros/0`/`empty_collection?/1`
  # are routing/classification, not producers, so they don't qualify a module on their own.)
  @producing_callbacks [
    mutate: 1,
    mutate: 2,
    pattern_mutations: 2,
    pattern_mutations: 3,
    return_replacements: 1,
    return_replacements: 2,
    condition_replacements: 1,
    condition_replacements: 2,
    host: 2
  ]

  @doc """
  Whether `term` is a module that implements this behaviour — it exports `name/0` and at least one
  mutation-producing callback (`mutate/1`, the pipe-aware `mutate/2`, or a structural hook such as
  `return_replacements/1`). Total over any term, so a non-module entry in a `:mutators` list is
  *reported* by resolution rather than crashing a guard.

      iex> Mutare.Mutator.implemented_by?(Mutare.Mutators.Arithmetic)
      true
      iex> Mutare.Mutator.implemented_by?(Enum)
      false
      iex> Mutare.Mutator.implemented_by?("arithmetic")
      false
  """
  @spec implemented_by?(term()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :name, 0) and
      Enum.any?(@producing_callbacks, fn {fun, arity} ->
        function_exported?(module, fun, arity)
      end)
  end

  # Total over any term: a non-atom (e.g. a string in `.mutare.exs`) is simply
  # not a mutator, so resolution reports it rather than crashing on the guard.
  def implemented_by?(_term), do: false

  @doc """
  Run every mutator over `node`, flattening to `{mutator, mutated_node}` pairs.

  The single place a node meets the mutator set. Both the in-place analyzer
  (`Mutare.Transform`) and the lifted-guard planner (`Mutare.Transform.FunctionPlan`)
  call this, so "which mutations does this node admit" has one answer regardless of
  where the node sits — placement is decided afterwards, positionally.

  Each entry is a `Mutare.Mutator.Spec` (a bare module is coerced to one); its
  `mutate/1` is always run, and its optional `mutate/2` is *also* run when
  implemented, with a per-spec `context` carrying the pipe mode **and** the spec's
  `:opts`. So pipe-aware/arity-changing *and* configurable mutators both
  participate here. `context` defaults to `%{pipe_mode: :unpiped}`; the transform passes
  `%{pipe_mode: :piped}` for a `|>` right-hand side. Each result is tagged with its
  **spec** (not the bare module), so the family name and config travel with it.

      iex> [{spec, mutated}] = Mutare.Mutator.mutations({:+, [], [1, 2]}, [Mutare.Mutators.Arithmetic])
      iex> {spec.name, mutated}
      {:arithmetic, {:-, [], [1, 2]}}
  """
  @spec mutations(Macro.t(), [Spec.t() | module()], context()) :: [{Spec.t(), Macro.t()}]
  def mutations(node, mutators, context \\ %{pipe_mode: :unpiped}) do
    Enum.flat_map(mutators, fn entry ->
      spec = Spec.coerce(entry)
      ctx = context |> Map.put(:opts, spec.opts) |> Map.put(:behaviours, spec.behaviours)
      node_local(spec, node) ++ contextual(spec, node, ctx)
    end)
  end

  # `mutate/1` is optional (a structural/pipe-only family omits it), so call it only when exported —
  # mirroring `contextual/1`'s guard on `mutate/2`.
  defp node_local(spec, node) do
    if function_exported?(spec.module, :mutate, 1),
      do: tag(spec, spec.module.mutate(node)),
      else: []
  end

  defp contextual(spec, node, context) do
    if function_exported?(spec.module, :mutate, 2),
      do: tag(spec, spec.module.mutate(node, context)),
      else: []
  end

  defp tag(_spec, :skip), do: []
  defp tag(spec, nodes) when is_list(nodes), do: Enum.map(nodes, &{spec, &1})

  @doc """
  Whether the mutation `{spec, mutated}` produces an **empty enumerable literal** — a
  value for which `x in v` is constantly `false`, so it is redundant on the right of `in`
  (the in-RHS suppression; see `Mutare.Transform.Analyze` / `Mutare.Transform.Tag`).

  Two sources, OR-ed: the shape-based `Mutare.AST.empty_collection_literal?/1` (the
  standard `[]`/`%{}`/`~w()`/`~c""`, recognised for any mutator), and the producing
  mutator's optional `c:empty_collection?/1` (its own non-standard shape — a custom sigil,
  `MapSet.new([])`, …). Dispatching on the *producing* spec's module is correct because
  only the mutator that emitted the value knows the shape of its own output.
  """
  @spec empty_collection?(Spec.t(), Macro.t()) :: boolean()
  def empty_collection?(%Spec{module: module}, mutated) do
    AST.empty_collection_literal?(mutated) or
      (function_exported?(module, :empty_collection?, 1) and module.empty_collection?(mutated))
  end
end
