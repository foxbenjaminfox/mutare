defmodule Mutare.Mutator do
  @moduledoc """
  Behaviour for mutators — pure functions over AST nodes.

  A mutator inspects a single AST node and returns either `:skip` (it does not apply here) or a list of mutated nodes, one per mutant to generate at that site.

  You must define `name/0` to identify the mutator in reports, and at least one of `mutate/1` or `mutate/2` to produce mutations. Optionally, you may implement `variants/0` and `variant/2` to classify your mutations into kinds, and `mutate_call_option_keys?/1` to control mutations of call-option names.

  Implement also `Mutare.Mutator.Structural` if you seek to participate in the structural mutation work—identifying a nonstandard position to mutate. (Amoung the built in mutators that use `Mutare.Mutator.Structural` are, for example, `Mutare.Mutators.ReturnValue`, `Mutare.Mutators.IfCondition`, and `Mutare.Mutators.PatternSwap`.)

  Implement also `Mutare.Mutator.MacroAware` if you target a macro whose arguments must be routed specially (e.g. a pattern, an opaque DSL body, a hosted fragment).

  ## Writing a mutator

  Match the node shapes you care about and rebuild them with the change, ideally reusing the original operand AST to keep the mutation minimal:

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
      you had better not produce a mutation that doesn't compile. 
    * **You don't choose placement.** Whether a mutation is delivered in place
      (a body expression) or by lifting (inside a `when` guard) is decided by
      *where the node sits*, not by the mutator. The same operator swap is used
      both ways.

  Build literal replacements with `Mutare.AST.literal/1` see `Mutare.AST` for the sentinels and node predicates. To match aliased/imported calls, resolve with `Mutare.Transform.Calls.resolved_call/1`.

  ## Registering a mutator

  List it under `:mutators` in `.mutare.exs` alongside (or instead of) the built-in family atoms:

      [mutators: [:arithmetic, :relational, MyApp.Mutators.Boolean]]

  ## Configuring a mutator (`{module, opts}`)

  To parametrize a mutator, register it with `{module, opts}` instead of a bare module. `opts` reaches the mutator through the `context` of `mutate/2` as `context.opts` — so a configurable mutator implements `mutate/2`:

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

  The reserved `:as` key in `opts` overrides the recorded family name (so the same module can run twice under distinct names); it is stripped before `opts` reaches the mutator. See `Mutare.Mutator.Spec`.

  A mutator that changes atom-like keys may optionally implement
  `c:mutate_call_option_keys?/1` to decide whether it wants to mutate a **call-option
  key** (a key of a keyword list passed as a call's final argument,
  `foo(x, timeout: 5)` → `timeout:`). The position is known only after the transform
  has analyzed the enclosing call, so this cannot be a `mutate/2` decision; the
  callback receives the mutator's own opts and owns the policy while the transform
  owns only detection and enforcement:

      # mutate option values but not the option names, for atom keys
      [mutators: [..., {Mutare.Mutators.AtomLiteral, call_option_keys: false}]]

  ## Targeting a macro / DSL (`Mutare.Mutator.MacroAware`)

  A mutator that targets a *macro* — whose arguments the transform must route as patterns,
  leave opaque, or host a fragment of — declares those macros through the separate
  `Mutare.Mutator.MacroAware` behaviour (`c:Mutare.Mutator.MacroAware.macros/0` and friends).
  Listing the mutator in `:mutators` auto-registers them, so a library (e.g. an Ecto
  integration) bundles its mutator and its macro routing in one module that declares both
  `Mutare.Mutator` and `Mutare.Mutator.MacroAware`. See `Mutare.Macros` for the declarative
  `:macros` option (the no-mutator case, e.g. routing a custom DSL's argument as a pattern).

  ## Structural mutators at routed positions (`Mutare.Mutator.Structural`)

  Some mutation targets are *positions* no single node identifies: a `def`/`defp` clause's
  **return tail**, an `if`/`unless`/`cond` **condition**, or a `def`/`defp` **head pattern**.
  Those live on the separate `Mutare.Mutator.Structural` behaviour — `mutate/1` is `:skip` and
  you implement `c:Mutare.Mutator.Structural.return_replacements/1`,
  `c:Mutare.Mutator.Structural.condition_replacements/1`, or
  `c:Mutare.Mutator.Structural.pattern_mutations/2` (declaring both `Mutare.Mutator` and
  `Mutare.Mutator.Structural`). The transform names the position and asks *every* enabled mutator
  implementing the callback, delivering each and
  recording it under its own name. `Mutare.Mutators.ReturnValue` / `Mutare.Mutators.IfCondition` /
  `Mutare.Mutators.PatternSwap` are the built-ins; a custom mutator participates identically.

  ## Behaviour-targeted mutators (`context.behaviours`)

  A mutator can fire differently — or only — inside modules that implement a given
  `@behaviour`. The enclosing module's behaviour set (a `MapSet` of module atoms, gathered
  from direct `@behaviour Foo` *and* `use`-injected ones like `use GenServer`) reaches a
  mutator under the context map's `:behaviours` key:

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
  `%{behaviours: …}` context: `c:Mutare.Mutator.Structural.return_replacements/2`,
  `c:Mutare.Mutator.Structural.condition_replacements/2`,
  `c:Mutare.Mutator.Structural.pattern_mutations/3`. Implement the `+1`-arity instead of the base
  to gate a return tail / condition / head pattern on the module's behaviours (e.g. a GenServer
  mutator that rewrites a `handle_call` return tail only under `@behaviour GenServer`); the
  transform prefers the context arity when exported. `test/support/behaviour_mutator.ex` is a
  working example covering both `mutate/2` and `return_replacements/2`.

  ## Matching aliased / imported calls (`Mutare.Transform.Calls`)

  A mutator that targets a stdlib/remote call should resolve the node with
  `Mutare.Transform.Calls.resolved_call/1` rather than pattern-matching the raw `Mod.fun(...)`:
  it returns `{module, fun, args, rebuild}` resolved through `alias`/`import`/Erlang-atom forms
  (or `nil`), so the mutator fires on `String.upcase`, `S.upcase`, and `import String; upcase`
  alike, and `rebuild` re-emits the swap in the form the source wrote. This is how the built-in
  call families reach aliased/imported calls; custom mutators get the same. See that module.
  """

  alias Mutare.Mutator.Mutation

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
      implements via `@behaviour Foo` (directly or injected by a `use`). Empty outside a
      module. This is how a
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
  One element of a `c:mutate/1`/`c:mutate/2` return list — **one of**:

    * `nil` — an empty slot, dropped (so a mutator may `Enum.map` over candidates and emit
      `nil` for the ones that don't apply, without filtering itself) — so to mutate a node
      *into* the literal `nil`, return the **wrapped** literal (`Mutare.AST.literal(nil)`),
      never a bare `nil` (which is the drop sentinel and would silently vanish);
    * a bare replacement **node** — an ordinary mutant, no note; or
    * a `t:Mutare.Mutator.Mutation.t/0` **struct** (`%Mutare.Mutator.Mutation{node:, note:}`) —
      a mutant carrying an advisory the report surfaces on its `Mutare.Site` (e.g. "kill may
      require NULL/boundary data").

  A bare `%{node:, note:}` *map* is **not** accepted — the struct is required (a quoted map
  literal is itself a valid mutation node, so only the struct unambiguously means "noted
  mutant"). The same three forms a selector host's `:mutants` accept (see
  `c:Mutare.Mutator.MacroAware.host/2`).
  """
  @type mutation :: nil | Macro.t() | Mutation.t()

  @doc """
  Return `:skip` when the mutator does not apply to `node`, otherwise a list of
  mutations (one per mutant) — each `nil` (dropped), a bare replacement node, or a
  `%Mutare.Mutator.Mutation{}` to attach an advisory the report shows on a survivor
  (see `t:mutation/0`).

  **Optional** — the entry point for a *node-level* mutator. A purely **structural** mutator
  (one driven by `Mutare.Mutator.Structural`) or a **pipe-aware/configurable** one (driven by
  `mutate/2`) produces no node-local mutation and simply omits this callback; `mutations/3` skips
  a mutator that doesn't export it. A module must still implement `name/0` plus at least one
  mutation-producing callback to count as a mutator.

  (The built-in `:guard_drop`/`:rescue_type` families are *not* mutators in this sense — they are
  **transform-managed**: their logic lives in `Mutare.Transform`, so they carry only `name/0`. See
  `Mutare.Mutators.transform_managed/0`.)
  """
  @callback mutate(Macro.t()) :: :skip | [mutation()]

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

  Returns the same `:skip | [t:mutation/0]` shape as `mutate/1` — so a `mutate/2` mutant
  may carry a note via `%Mutare.Mutator.Mutation{}` exactly as `mutate/1`'s can.
  """
  @callback mutate(Macro.t(), context()) :: :skip | [mutation()]

  @doc """
  Optional hook declaring this mutator's **variant vocabulary** — the labels a user may write in a
  qualified `# mutare:ignore[family:label]` directive to suppress *one* kind of mutation it
  produces rather than the whole family.

  A single source node often yields several sibling mutants (`Mutare.Mutators.Relational`'s
  `i < j` becomes both `i <= j` and `i > j`); without a vocabulary, `# mutare:ignore[relational]`
  can only suppress *all* of them. By declaring labels — and assigning each mutation one — a mutator
  lets `# mutare:ignore[relational:>]` name just the `i > j` reflection while `i <= j` keeps running.

  **Declaring `variants/0` is how a mutator opts in.** It then assigns labels to its mutations one
  of two ways (pick whichever is cleaner for the family):

    * **Tag at production** — return a `Mutare.Mutator.Mutation.tagged(node, label)` from
      `c:mutate/1`/`c:mutate/2`, attaching the label where the mutant is built. Best when the
      *kind* is known at construction (a value family: `tagged(AST.literal(0), "zero")`).
    * **Derive afterwards** — implement `c:variant/2`, which classifies the `{original, mutated}`
      pair. Best when the label reads cleanly off the node (an operator family:
      `op_swap_variant/3` over the swapped operator).

  So `c:variant/2` is **optional** — a tagging mutator omits it. A mutator with no `variants/0`
  vocabulary supports only the bare `[family]` filter, and a qualifier against it is a hard error —
  so a user's typo is reported with a clear message rather than silently failing to match.

  Each label must be a **wire-safe** token — no whitespace, `,`, `(`, `)`, `]`, or `"`, and not
  empty — so it can be written as a `[family:label]` qualifier. The vocabulary you choose is your
  mutator's public contract (users write it in source comments), so prefer stable, self-describing
  names: operator symbols (`relational` → `> >= < <= == != === !==`) or semantic kinds
  (`return_value` → `empty sentinel`, `literal` → `zero succ pred negate`).
  """
  @callback variants() :: [String.t() | atom()]

  @doc """
  Optional hook deriving one produced mutation's **variant label(s)** from its `{original, mutated}`
  nodes (see `c:variants/0`) — the *derive-afterwards* alternative to tagging the mutation at
  production with `Mutare.Mutator.Mutation.tagged/2`. A mutator that tags at production omits this.

  Given the `original` node and the `mutated` node it produced, return the label naming *which
  kind* of mutation it is — a member of `c:variants/0` — or `nil` for a mutation with no label
  (matchable only by the bare `[family]` filter). The label is recorded on the mutant and is what a
  `[family:label]` qualifier matches; matching is case-insensitive. Requires `c:variants/0` (it
  declares the vocabulary this validates against); a `variant/2` without `variants/0` is inert.

  A single mutant may belong to **more than one kind** — return a *list* of labels and a qualifier
  naming any of them suppresses it. For instance, when a value family's mutation collapses two
  relationships onto one value (`Mutare.Mutators.Literal`'s `1 - 1` and its `0` sentinel are the
  same `0` after dedup), returning `["pred", "zero"]` lets *both* `[literal:pred]` and
  `[literal:zero]` select it. A `nil`, a single label, and a list of labels are all accepted; most
  mutations are a single kind.

  Classify from the `{original, mutated}` *pair*, not the mutated node alone — a strip
  mutation (`-(a + b)` → `a + b`) emits a node whose head (`+`) would otherwise be
  mis-read as an operator swap. The operator families share the `Mutare.Mutator.op_swap_variant/3`
  helper for this (a strip's *unary* original can't match a 2-arg swap, so it returns `nil`):

      # in Mutare.Mutators.Relational
      @swap_ops [:>, :>=, :<, :<=, :==, :!=, :===, :!==]
      def variants, do: Enum.map(@swap_ops, &to_string/1)
      def variant(original, mutated),
        do: Mutare.Mutator.op_swap_variant(original, mutated, @swap_ops)
  """
  @callback variant(original :: Macro.t(), mutated :: Macro.t()) ::
              String.t() | atom() | [String.t() | atom()] | nil

  @doc """
  Optional policy hook for mutations of a call's trailing keyword-option keys.

  The transform invokes this only for a candidate already identified as mutating an
  option key in a call such as `foo(timeout: 5)`. It passes the producing mutator
  instance's configured `opts`; return `true` to keep the candidate or `false` to
  suppress it. A mutator without this callback keeps such candidates.

  This hook is deliberately mutator-owned rather than a transform-wide option:
  context-free atom replacement tends to turn an option name into an ignored unknown
  key, while a call-aware family may replace a known key with another legal key and
  should remain enabled. `Mutare.Mutators.AtomLiteral` and
  `Mutare.Mutators.ConventionAtom` implement it; `Mutare.Mutators.ModeSwap` does not.

  The hook is separate from `c:mutate/2` because a key node is offered to mutators
  before its enclosing call has been reassembled and classified.
  """
  @callback mutate_call_option_keys?(opts :: term()) :: boolean()

  @optional_callbacks mutate: 1,
                      mutate: 2,
                      mutate_call_option_keys?: 1,
                      variants: 0,
                      variant: 2

  @typedoc """
  A call node's pipe context, as an atom: `:piped` (the node is a `|>` right-hand
  side, so its effective first argument is the pipe's left side) or `:unpiped`.
  It is what the `mutate/2` context's `:pipe_mode` carries, and the form
  `effective_arity/2` and `visible_index/2` take.
  """
  @type pipe_mode :: :piped | :unpiped

  @doc """
  The **effective arity** of a call node given its pipe context (`:piped`/`:unpiped`).

  A pipe stage (`x |> f(a)`) carries one fewer argument than the source reads: its
  effective first argument is the `|>` left side, which Elixir splices in only after
  this transform runs, so it is *not* in the node's own `args`. A pipe-aware mutator
  (`mutate/2`) recovers the real arity as `length(args)`, plus one when `:piped`.
  `Mutare.Mutators.CollectionArity` is the built-in example.

  The pipe context (`:piped`/`:unpiped`) comes from the `mutate/2` context's
  `:pipe_mode` key.

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
  shifts down by one. Unpiped, effective and visible indices coincide.
  `Mutare.Mutators.ModeSwap` and `Mutare.Mutators.CollectionArity` use it.

  The pipe context (`:piped`/`:unpiped`) comes from the `mutate/2` context's
  `:pipe_mode` key.

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
  Classify a **binary operator swap** for `c:variant/2`: when `original` and `mutated` are both
  two-argument operator nodes whose heads are in `ops`, the label is `to_string(new_op)`; otherwise
  `nil`. A ready-made `c:variant/2` for an operator family — pass your swap-operator set and it
  reads the label off the result. It takes the `{original, mutated}` *pair* so a strip (whose
  original is *unary*) can't be mistaken for a swap.

      def variant(o, m), do: Mutare.Mutator.op_swap_variant(o, m, @swap_ops)
  """
  @spec op_swap_variant(Macro.t(), Macro.t(), [atom()]) :: String.t() | nil
  def op_swap_variant({op, _m, [_l, _r]}, {new, _m2, [_, _]}, ops) when is_list(ops) do
    if op in ops and new in ops, do: to_string(new), else: nil
  end

  def op_swap_variant(_original, _mutated, _ops), do: nil

  @doc false
  # Fold a declared/recorded variant label to its canonical form (`to_string/1` then downcased) —
  # the case-insensitive matching contract the declaring, recording, and filter-parsing sides share,
  # so a declared `TRUE` label matches a `[conditional:true]` filter.
  @spec normalize_label(String.t() | atom()) :: String.t()
  def normalize_label(label), do: label |> to_string() |> String.downcase()
end
