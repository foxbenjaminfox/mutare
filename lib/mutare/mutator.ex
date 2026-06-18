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
  `opts` reaches the mutator through the `context` of `mutate/2` (and
  `owned_args/2`) as `context.opts` — so a configurable mutator implements
  `mutate/2`:

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
  """

  alias Mutare.Mutator.Spec

  @typedoc """
  Context threaded to the optional `mutate/2` and `owned_args/2` at each runtime
  call site. Carries:

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
  Optional hook by which a mutator claims **exclusive ownership** of one or more of a
  call's *argument positions*, so the transform does not also offer those leaves to
  *other* mutators in place.

  Given a runtime call node and the same `context` as `mutate/2`
  (`%{piped: boolean, opts: term}`), it returns the **visible** argument indices (into
  the node's own arg list, the piped value excluded) that this mutator already covers
  via the *whole call* — positions
  where another mutator firing in place would only add a redundant, often nonsensical
  mutant. `Mutare.Mutators.ModeSwap` is the built-in user: it swaps a unit/mode atom
  (`DateTime.truncate(dt, :second)` → `:millisecond`) by rewriting the call, so it owns
  that atom's position and `Mutare.Mutators.AtomLiteral` no longer turns the same
  `:second` into the sentinel `:mutare` (a mutant that would just raise).

  A mutator should claim a position **only when it actually mutates it** (so a position
  it leaves untouched — an unrecognised atom, a variable — stays available to others).
  `Mutare.Transform` discovers implementers by `function_exported?(mod, :owned_args, 2)`
  and routes owned positions through a non-mutating context; a mutator without this
  callback claims nothing. When the claimed argument is a **keyword list** (ModeSwap's
  `shift` duration), only its *keys* are routed non-mutating — the values stay runtime, so
  other mutators still see them (a claim there owns the option names, not the values).
  """
  @callback owned_args(Macro.t(), context()) :: [non_neg_integer()]

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

  @optional_callbacks pattern_mutations: 2, mutate: 2, owned_args: 2, macros: 0

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
end
