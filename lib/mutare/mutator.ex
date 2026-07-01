defmodule Mutare.Mutator do
  @moduledoc """
  Behaviour for mutators: modules that produce AST replacements.

  A mutator examines an AST node and returns either `:skip` or a list of
  mutations to generate at that site. Every mutator defines `name/0` and at least
  one mutation-producing callback.

  Use `mutate/1` for ordinary node-level mutations. Use `mutate/2` when the
  mutation needs context such as pipe mode, configuration options, or enclosing
  behaviours. Use `variants/0` and `variant/2` when individual mutation kinds
  should be addressable by `# mutare:ignore[family:label]`. Use
  `mutate_call_option_keys?/1` to control mutations of trailing call-option names.

  When both `mutate/1` and `mutate/2` are exported, Mutare calls `mutate/2`.
  If a mutator needs both context-free and context-aware production, call the
  context-free helper explicitly from `mutate/2`.

  Structural positions use `Mutare.Mutator.Structural`. Macro-aware mutators use
  `Mutare.MacroRouting`, and mutators that emit mutations inside hosted DSL
  fragments also use `Mutare.Mutator.MacroHost`.

  ## Writing a mutator

  Match the node shapes to mutate and rebuild them with the changed node. Reuse the
  original operand AST when possible so the mutation stays small:

      defmodule MyApp.Mutators.Boolean do
        @behaviour Mutare.Mutator

        @impl true
        def name, do: :boolean

        @impl true
        def mutate({:and, meta, [left, right]}), do: [{:or, meta, [left, right]}]
        def mutate({:or, meta, [left, right]}), do: [{:and, meta, [left, right]}]
        def mutate(_node), do: :skip
      end

  Two rules are important:

    * **Keep every replacement compile-safe.** Mutare compiles one shared
      metamutant containing all emitted mutants.
    * **Do not choose delivery placement.** The transform decides whether a
      mutation is delivered in place or through lifting based on where the node
      appears.

  Build literal replacements with `Mutare.AST.literal/1`. Use
  `Mutare.Transform.Calls.resolved_call/1` when matching aliased or imported calls.

  ## Registering a mutator

  List it under `:mutators` in `.mutare.exs` alongside, or instead of, built-in
  family atoms:

      [mutators: [:arithmetic, :relational, MyApp.Mutators.Boolean]]

  ## Configuring a mutator (`{module, opts}`)

  Register a configurable mutator as `{module, opts}`. The options are available as
  `context.opts`. Node-level configurable mutators implement `mutate/2`:

      defmodule MyApp.Mutators.MagicNumber do
        @behaviour Mutare.Mutator
        def name, do: :magic_number

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

  The reserved `:as` key changes the recorded family name, allowing the same module
  to run more than once under distinct names. It is removed before options reach the
  mutator. See `Mutare.Mutator.Spec`.

  Structural mutators use the context-aware structural arity instead:
  `c:Mutare.Mutator.Structural.return_replacements/2`,
  `c:Mutare.Mutator.Structural.condition_replacements/2`, or
  `c:Mutare.Mutator.Structural.pattern_mutations/3`.

  A mutator that changes atom-like keys may implement
  `c:mutate_call_option_keys?/1` to decide whether to mutate a trailing call-option
  key such as `timeout:` in `foo(x, timeout: 5)`. This policy belongs to the
  mutator because a context-free atom replacement may turn an option name into an
  unknown key, while a call-aware family may replace one legal option key with
  another.

      [mutators: [..., {Mutare.Mutators.AtomLiteral, call_option_keys: false}]]

  ## Targeting a macro or DSL

  A mutator whose target macro needs special argument routing implements
  `Mutare.MacroRouting` and registers routes from
  `c:Mutare.MacroRouting.macro_routes/0`. Routes may be static or shape-aware via
  `c:Mutare.MacroRouting.macro_routing/1`. Listing the mutator in `:mutators`
  registers those routes.

  A mutator that produces mutations inside a compile-time DSL also implements
  `Mutare.Mutator.MacroHost`. Routing stays in `Mutare.MacroRouting`; the host
  delivers DSL-specific mutations through `c:Mutare.Mutator.MacroHost.host/2`.

  ## Structural mutators at routed positions (`Mutare.Mutator.Structural`)

  Some targets are positions rather than individual nodes: a `def`/`defp` return
  tail, an `if`/`unless`/`cond` condition, or a structural pattern position.
  Pattern positions include `def`/`defp` heads, clause patterns, destructuring match
  patterns, and routed `:binding_pattern` macro arguments. Those callbacks live on
  `Mutare.Mutator.Structural`. A structural mutator declares both behaviours and
  implements the relevant structural callback.

  The transform identifies the position, asks each enabled mutator that exports the
  matching callback, and records each emitted mutation under that mutator's name.
  Built-in examples are `Mutare.Mutators.ReturnValue`,
  `Mutare.Mutators.IfCondition`, and `Mutare.Mutators.PatternSwap`.

  ## Behaviour-targeted mutators (`context.behaviours`)

  A mutator can depend on behaviours implemented by the enclosing module. The
  behaviour set is available as `context.behaviours`, a `MapSet` of module atoms
  gathered from direct `@behaviour` attributes and `use`-injected behaviours.

      defmodule MyApp.Mutators.GenServerReply do
        @behaviour Mutare.Mutator
        def name, do: :genserver_reply

        def mutate({:{}, m, [{:__block__, am, [:reply]}, _r, state]}, %{behaviours: bs}) do
          if MapSet.member?(bs, GenServer),
            do: [{:{}, m, [{:__block__, am, [:noreply]}, state]}],
            else: :skip
        end

        def mutate(_node, _context), do: :skip
      end

  Structural callbacks have context-aware arities carrying the same behaviour set:
  `c:Mutare.Mutator.Structural.return_replacements/2`,
  `c:Mutare.Mutator.Structural.condition_replacements/2`, and
  `c:Mutare.Mutator.Structural.pattern_mutations/3`. These callbacks receive
  `context.behaviours` and `context.opts`, so export the context-aware arity when a
  structural mutation depends on behaviours or configuration.

  ## Matching aliased or imported calls (`Mutare.Transform.Calls`)

  A mutator that targets a standard-library or remote call uses
  `Mutare.Transform.Calls.resolved_call/1`. It returns
  `{module, function, arguments, rebuild}` for resolved qualified, aliased,
  imported, and Erlang-atom module calls. `rebuild` emits the replacement in the
  same written form as the source.
  """

  alias Mutare.Mutator.Mutation

  @typedoc """
  Context passed to `mutate/2` at each runtime call site.

    * `:pipe_mode` — `:piped` or `:unpiped`; when piped, the effective first
      argument is the pipe's left side and is not present in the node's own args.
    * `:opts` — the configured mutator's per-instance options (the `opts` of a
      `{module, opts}` entry in `:mutators`, with any `:as` name override
      stripped), or `[]` for an unconfigured mutator.
    * `:behaviours` — the enclosing module's behaviour set: a `MapSet` of the modules it
      implements via `@behaviour Foo` (directly or injected by a `use`). Empty outside a
      module.

  `:opts` and `:behaviours` are optional in the type because the base context
  carries only `:pipe_mode`; dispatch injects the configured options and behaviour
  set before calling a mutator.
  """
  @type context :: %{
          :pipe_mode => pipe_mode(),
          optional(:opts) => term(),
          optional(:behaviours) => MapSet.t(module())
        }

  @typedoc """
  One element of a `c:mutate/1` or `c:mutate/2` return list.

    * A bare AST node is an ordinary replacement. A top-level bare `nil` item is
      rejected because it is too easy to confuse with “no replacement”; filter
      inapplicable entries before returning the list. To replace a node with the
      literal `nil`, return `Mutare.AST.literal(nil)`.
    * A `t:Mutare.Mutator.Mutation.t/0` carries a replacement plus metadata such
      as a report note or ignore variant.

  A plain map is not treated as mutation metadata because a quoted map is also a
  valid AST replacement. Selector hosts use the same forms for `:mutants`.
  """
  @type mutation :: Macro.t() | Mutation.t()

  @doc """
  Produces node-level mutations for `node`.

  Return `:skip` when the mutator does not apply. Otherwise return one
  `t:mutation/0` entry per mutant. This callback is optional when a mutator
  produces mutations only through `mutate/2` or `Mutare.Mutator.Structural`.

  Transform-managed families such as `:guard_drop` and `:rescue_type` are
  registered for configuration and reporting but do not implement this callback.
  """
  @callback mutate(Macro.t()) :: :skip | [mutation()]

  @doc "Short family name, shown in reports (e.g. `:arithmetic`)."
  @callback name() :: atom()

  @doc """
  Produces context-aware mutations for `node`.

  This callback is used for pipe-aware, configurable, and behaviour-targeted
  mutators. `context.pipe_mode` lets a mutator compute effective arity for piped
  calls; `context.opts` carries per-instance configuration; `context.behaviours`
  carries the enclosing module's behaviour set.

  When both `mutate/1` and `mutate/2` are exported, this callback takes
  precedence. Mutare does not also call `mutate/1`. To compose them, call
  `mutate/1` from `mutate/2` and combine the results explicitly. The return
  shape is the same as `mutate/1`.
  """
  @callback mutate(Macro.t(), context()) :: :skip | [mutation()]

  @doc """
  Declares the variant labels this mutator supports in
  `# mutare:ignore[family:label]` filters.

  A single source node may produce several sibling mutants. Variant labels allow a
  directive to suppress one kind without suppressing the whole family.

  A mutator that declares variants assigns labels in one of two ways:

    * **Tag at production** — return a `Mutare.Mutator.Mutation.tagged(node, label)` from
      `c:mutate/1`/`c:mutate/2`, attaching the label where the mutant is built. Best when the
      *kind* is known at construction (a value family: `tagged(AST.literal(0), "zero")`).
    * **Derive afterwards** — implement `c:variant/2`, which classifies the `{original, mutated}`
      pair. Best when the label reads cleanly off the node (an operator family:
      `op_swap_variant/3` over the swapped operator).

  A tagging mutator does not need `c:variant/2`. A mutator with no variant
  vocabulary supports only the bare `[family]` filter; a qualified filter against
  it is an error.

  Labels must be non-empty wire-safe tokens: no whitespace, `,`, `(`, `)`, `]`,
  or `"`. Treat labels as public API because users write them in source comments.
  """
  @callback variants() :: [String.t() | atom()]

  @doc """
  Derives variant labels from an emitted `{original, mutated}` pair.

  Return one label, a list of labels, or `nil`. Labels must be members of
  `c:variants/0` and are matched case-insensitively by ignore directives.

  Classify from both nodes, not the mutated node alone. For example, a strip
  mutation such as `-(a + b)` → `a + b` emits a `+` node but is not an operator
  swap. Operator families can use `op_swap_variant/3` for this pattern:

      # in Mutare.Mutators.Relational
      @swap_ops [:>, :>=, :<, :<=, :==, :!=, :===, :!==]
      def variants, do: Enum.map(@swap_ops, &to_string/1)
      def variant(original, mutated),
        do: Mutare.Mutator.op_swap_variant(original, mutated, @swap_ops)
  """
  @callback variant(original :: Macro.t(), mutated :: Macro.t()) ::
              String.t() | atom() | [String.t() | atom()] | nil

  @doc """
  Controls mutation of trailing keyword-option keys.

  The transform calls this after identifying a candidate that mutates a call option
  key such as `timeout:` in `foo(timeout: 5)`. Return `true` to keep the
  candidate or `false` to suppress it. A mutator without this callback keeps the
  candidate.

  The callback receives the mutator instance's configured options. It is separate
  from `c:mutate/2` because option-key detection happens after the key node has
  already been offered to mutators.
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
  Returns the effective arity of a call under its pipe context.

  A piped call stage has one implicit argument: the left side of the pipe. That
  argument is not present in the call node's own argument list, so piped arity is
  `length(args) + 1`.

      iex> Mutare.Mutator.effective_arity([:a, :b], :unpiped)
      2
      iex> Mutare.Mutator.effective_arity([:b], :piped)
      2
  """
  @spec effective_arity([Macro.t()], pipe_mode()) :: non_neg_integer()
  def effective_arity(args, :piped) when is_list(args), do: length(args) + 1
  def effective_arity(args, :unpiped) when is_list(args), do: length(args)

  @doc """
  Converts an effective argument index to the index in the call node's visible
  argument list.

  In piped calls, effective index `0` is the pipe's left side and has no visible
  index, so the function returns `nil`. Later indexes shift down by one. In
  unpiped calls, effective and visible indexes are the same.

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
  Classifies a binary operator swap for `c:variant/2`.

  When `original` and `mutated` are both two-argument operator nodes whose heads
  are in `ops`, returns the new operator as a string. Otherwise returns `nil`.
  Checking both nodes prevents unary strip mutations from being classified as
  binary swaps.

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
