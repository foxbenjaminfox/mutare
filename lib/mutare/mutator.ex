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
        def mutate(_node), do: :skip

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

    * `:piped` — whether the node is the right-hand side of a `|>` (so its
      effective first argument is the pipe's left side, *not* present in the
      node's own args). A mutator computes effective arity with `effective_arity/2`.
    * `:opts` — the configured mutator's per-instance options (the `opts` of a
      `{module, opts}` entry in `:mutators`, with any `:as` name override
      stripped), or `[]` for an unconfigured mutator. This is how a configurable
      mutator receives its parameters — see `Mutare.Mutator.Spec`.

  `:opts` is `optional` in the type because the *base* context threaded through
  `mutations/3` carries only `:piped`; `mutations/3` injects each spec's `:opts`
  before invoking a mutator, so a callback always sees it at runtime.
  """
  @type context :: %{:piped => boolean(), optional(:opts) => term()}

  @doc """
  Return `:skip` when the mutator does not apply to `node`, otherwise a list of
  mutated nodes (one per mutant).
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
  (`%{piped: boolean, opts: term}`); a mutator uses `context.piped` to recover the
  effective arity. Used for arity-*changing* call mutations (dropping a refining
  argument, collapsing to a coarser call) that `mutate/1` cannot express safely —
  see `Mutare.Mutators.CollectionArity`. A mutator that implements this typically
  returns `:skip` from `mutate/1` (it never fires node-locally). Discovered by
  `function_exported?(mod, :mutate, 2)`; a mutator without it takes no part.

  This is also the callback a **configurable** mutator implements to read its
  options: `context.opts` carries the `opts` of its `{module, opts}` entry in
  `:mutators` (see `Mutare.Mutator.Spec`). Unlike pipe-aware mutators it need not
  return `:skip` from `mutate/1`, but since `mutate/1` has no context, a mutator
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
  Optional hook by which a mutator registers the **known macros** it depends on —
  macros whose arguments the transform must route specially (a pattern argument, an
  opaque DSL body) for this mutator to work, or simply to keep core from mutating a
  DSL it does not understand.

  Returns a list of `Mutare.Macro.Spec` entries in the declarative form
  `{module, name, arity, treatment}` or `{module, name, treatment}` (arity `:any`),
  where `treatment` is `:expression` / `:pattern` / `:skip` (uniform) or a
  per-position list. When the mutator is enabled (listed in `:mutators`), the
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
  Optional structural hook for mutating an **`if`/`unless`/`cond` condition**. Given the raw
  condition node, return the replacement nodes (one per mutant). The condition-position twin
  of `c:return_replacements/1`: structural, discovered by
  `function_exported?(mod, :condition_replacements, 1)`, delivered in place.
  `Mutare.Mutators.IfCondition` is the built-in (forcing the condition `true`/`false`); a
  custom mutator implementing it participates at the same positions. Return `[]` to skip.
  """
  @callback condition_replacements(condition :: Macro.t()) :: [Macro.t()]

  @optional_callbacks pattern_mutations: 2,
                      mutate: 2,
                      macros: 0,
                      empty_collection?: 1,
                      return_replacements: 1,
                      condition_replacements: 1

  @doc """
  The **effective arity** of a call node given its pipe context.

  A pipe stage (`x |> f(a)`) carries one fewer argument than the source reads: its
  effective first argument is the `|>` left side, which Elixir splices in only after
  this transform runs, so it is *not* in the node's own `args`. A pipe-aware mutator
  (`mutate/2`) recovers the real arity as `length(args) + if(piped?, do: 1, else: 0)`.
  The single home for that off-by-one — see `Mutare.Mutators.CollectionArity` et al.
  """
  @spec effective_arity([Macro.t()], boolean()) :: non_neg_integer()
  def effective_arity(args, piped?) when is_list(args),
    do: length(args) + if(piped?, do: 1, else: 0)

  @doc """
  Map an **effective** argument index to the index into a call node's *visible*
  `args`, given pipe context — the inverse of the `effective_arity/2` off-by-one.

  When piped, effective index `0` is the `|>` left side, which isn't in the
  node's own `args`, so it has no visible index (`nil`) and every later index
  shifts down by one. Unpiped, effective and visible indices coincide. The single
  home for that mapping — see `Mutare.Mutators.{ModeSwap,CollectionArity}`.
  """
  @spec visible_index(non_neg_integer(), boolean()) :: non_neg_integer() | nil
  def visible_index(pos, false), do: pos
  def visible_index(0, true), do: nil
  def visible_index(pos, true), do: pos - 1

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

  @doc "Whether `term` is a module that implements this behaviour."
  @spec implemented_by?(term()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :mutate, 1) and
      function_exported?(module, :name, 0)
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
  implemented, with a per-spec `context` carrying the pipe flag **and** the spec's
  `:opts`. So pipe-aware/arity-changing *and* configurable mutators both
  participate here. `context` defaults to a non-piped node; the transform passes
  `%{piped: true}` for a `|>` right-hand side. Each result is tagged with its
  **spec** (not the bare module), so the family name and config travel with it.
  """
  @spec mutations(Macro.t(), [Spec.t() | module()], context()) :: [{Spec.t(), Macro.t()}]
  def mutations(node, mutators, context \\ %{piped: false}) do
    Enum.flat_map(mutators, fn entry ->
      spec = Spec.coerce(entry)
      ctx = Map.put(context, :opts, spec.opts)
      tag(spec, spec.module.mutate(node)) ++ contextual(spec, node, ctx)
    end)
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
