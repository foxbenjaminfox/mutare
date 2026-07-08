defmodule Mutare.Mutator do
  @moduledoc """
  Behaviour for mutators: modules that produce AST replacements.

  A mutator examines an AST node and returns either `:skip` or a list of mutations to generate at that site. Every mutator defines `name/0` and at least one mutation-producing callback.

  You must define `name/0` to identify the mutator in reports, and at least one mutation-producing callback. The usual producer is `mutate/1` (or the pipe-aware/configurable `mutate/2`), but a `Mutare.Mutator.Structural` hook or a `c:Mutare.Mutator.MacroHost.host/2` selector host counts too — a mutator that produces *only* through one of those needs no `mutate/1`. Optionally, you may implement `variants/0` and `variant/2` to classify your mutations into kinds, `mutate_call_option_keys?/1` to control mutations of call-option names, and `argument_marks/1` to have the transform *mark* specific call-argument positions (e.g. timeout literals) that you then recognise with `marked?/2` in `mutate/2` and decline.

  When both `mutate/1` and `mutate/2` are exported, Mutare calls `mutate/2`. If a mutator needs both context-free and context-aware production, call the context-free helper explicitly from `mutate/2`.

  Structural positions use `Mutare.Mutator.Structural`. Macro-aware mutators use `Mutare.MacroRouting`, and mutators that emit mutations inside hosted DSL fragments also use `Mutare.Mutator.MacroHost`.

  ## Writing a mutator

  Match the node shapes to mutate and rebuild them with the changed node. Reuse the original operand AST when possible so the mutation stays small:

      defmodule MyApp.Mutators.AndOr do
        @behaviour Mutare.Mutator

        @impl true
        def name, do: :and_or

        @impl true
        def mutate({:and, meta, [left, right]}), do: [{:or, meta, [left, right]}]
        def mutate({:or, meta, [left, right]}), do: [{:and, meta, [left, right]}]
        def mutate(_node), do: :skip
      end

  Two rules are important:

    * Keep every replacement compile-safe. Mutare compiles one shared metamutant containing all emitted mutants.
    * Do not choose delivery placement. The transform decides whether a mutation is delivered in place or through lifting based on where the node appears.

  Build literal replacements with `Mutare.AST.literal/1`. Use `Mutare.Calls.resolved_call_to/3` when matching aliased or imported calls.

  ## Registering a mutator

  List it under `:mutators` in `.mutare.exs` alongside, or instead of, built-in family atoms:

      [mutators: [:arithmetic, :relational, MyApp.Mutators.AndOr]]

  ## Configuring a mutator (`{module, opts}`)

  Register a configurable mutator as `{module, opts}`. The options are available as `context.opts`. Node-level configurable mutators implement `mutate/2`:

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

  The reserved `:as` key changes the recorded family name, allowing the same module to run more than once under distinct names. It is removed before options reach the mutator. See `Mutare.Mutator.Spec`.

  A mutator with a rich option surface implements `c:init/1` to parse and validate its options once, when the instance is resolved — before any file is read — instead of re-reading `context.opts` at every offered node. The value `init/1` returns reaches every context-aware callback as `context.config`; a typo'd option raises at startup, next to Mutare's own option validation. Without `init/1`, `context.config` is the raw options. For the common "which of my families are enabled" option, see `Mutare.Mutator.Families`.

  A mutator that must post-process everything it produces — typically to apply that family selection and attach per-family report notes — implements `c:finalize/2`, which Mutare applies to every produced mutation on every delivery path (a `mutate/1`/`mutate/2` return and a hosted target's `:mutants`) just before recording, so the funnel cannot miss a delivery site.

  Structural mutators use the context-aware structural arity instead: `c:Mutare.Mutator.Structural.return_replacements/2`, `c:Mutare.Mutator.Structural.condition_replacements/2`, or `c:Mutare.Mutator.Structural.pattern_mutations/3`.

  A mutator that changes atom-like keys may implement `c:mutate_call_option_keys?/1` to decide whether to mutate a trailing call-option key such as `timeout:` in `foo(x, timeout: 5)`. This policy belongs to the mutator because a context-free atom replacement may turn an option name into an unknown key, while a call-aware family may replace one legal option key with another.

      [mutators: [..., {Mutare.Mutators.AtomLiteral, call_option_keys: false}]]

  ## Targeting a macro or DSL

  A mutator whose mutation depends on a macro's arguments being routed specially implements `Mutare.MacroRouting` and registers the macros from `c:Mutare.MacroRouting.macro_routes/0`. Routes may be static or use `:routing` with `c:Mutare.MacroRouting.route_arguments/2` for shape-aware classification. Listing the mutator in `:mutators` auto-registers them.

  Core still offers the *whole* registered call to `c:mutate/2`, with `context.mutators` carrying the run's enabled specs — so a mutator that keeps a DSL argument raw (`:skip`) can rewrite the call itself and sub-contract the ordinary-Elixir islands inside that raw argument back to core's generation via `Mutare.Analyze.expression_mutations/3`, relaying each rebuild as a `Mutare.Mutator.Mutation` with `producer:` set (see `Mutare.Analyze` — the island is analyzed with the full set, so another mutator's registered macro inside it is offered to *its* owner the same way).

  A mutator that produces mutations *inside* a compile-time DSL additionally implements `Mutare.Mutator.MacroHost`, subscribes with `c:Mutare.Mutator.MacroHost.hosted_macros/0`, and delivers foreign-DSL mutations through `c:Mutare.Mutator.MacroHost.host/2`. It need not own the DSL's routing: a separate extension may declare the `:hosted` position, and several hosts may subscribe to it. See the "which behaviours do I implement?" table in `Mutare.MacroRouting`.

  ## Structural mutators at routed positions (`Mutare.Mutator.Structural`)

  Some targets are positions rather than individual nodes: a `def`/`defp` return tail, an `if`/`unless`/`cond` condition, or a structural pattern position. Pattern positions include `def`/`defp` heads, clause patterns, destructuring match patterns, and routed `:binding_pattern` macro arguments. Those callbacks live on `Mutare.Mutator.Structural`. A structural mutator declares both behaviours and implements the relevant structural callback.

  The transform identifies the position, asks each enabled mutator that exports the matching callback, and records each emitted mutation under that mutator's name. Built-in examples are `Mutare.Mutators.ReturnValue`, `Mutare.Mutators.IfCondition`, and `Mutare.Mutators.PatternSwap`.

  ## Behaviour-targeted mutators (`context.behaviours`)

  A mutator can depend on behaviours implemented by the enclosing module. The behaviour set is available as `context.behaviours`, a `MapSet` of module atoms gathered from direct `@behaviour` attributes and `use`-injected behaviours.

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

  Structural callbacks have context-aware arities carrying the same behaviour set: `c:Mutare.Mutator.Structural.return_replacements/2`, `c:Mutare.Mutator.Structural.condition_replacements/2`, and `c:Mutare.Mutator.Structural.pattern_mutations/3`. These callbacks receive `context.behaviours` and `context.opts`, so export the context-aware arity when a structural mutation depends on behaviours or configuration.

  ## Matching aliased or imported calls (`Mutare.Calls`)

  A mutator that targets a standard-library or remote call uses `Mutare.Calls.resolved_call_to/3` with the real module atom (and optionally the function names it owns); it returns `{:ok, function, arguments, rebuild}` for resolved qualified, aliased, imported, and Erlang-atom module calls, and `rebuild` emits the replacement in the same written form as the source. For table-driven matching across modules, `Mutare.Calls.resolved_call/1` returns the raw resolved tuple, keyed by `Mutare.Calls.module_key/1`.
  """

  alias Mutare.Mutator.Mutation

  @typedoc """
  Context passed to `mutate/2` at each runtime call site.

    * `:pipe_mode` — `:piped` or `:unpiped`; when piped, the effective first
      argument is the pipe's left side and is not present in the node's own args.
    * `:opts` — the configured mutator's per-instance options (the `opts` of a
      `{module, opts}` entry in `:mutators`, with any `:as` name override
      stripped), or `[]` for an unconfigured mutator.
    * `:config` — the mutator's normalized configuration: what its `c:init/1`
      returned for those options, or the raw options themselves when the mutator
      does not export `init/1`.
    * `:behaviours` — the enclosing module's behaviour set: a `MapSet` of the modules it
      implements via `@behaviour Foo` (directly or injected by a `use`). Empty outside a
      module.
    * `:mutators` — present for selector hosts (`c:Mutare.Mutator.MacroHost.host/2`) and for
      the whole-call `mutate/2` offer of a **registered macro call** (a call some enabled
      mutator or extension registered via `Mutare.MacroRouting`): the run's enabled
      `Mutare.Mutator.Spec`s (hosts included), for sub-contracting ordinary-Elixir islands the
      macro's routing left raw back to core's generation via
      `Mutare.Analyze.expression_mutations/3` — which lowers a nested host's targets to
      whole-call rebuilds instead of weaving them, so hosted delivery never nests while every
      surface (ordinary and hosted) participates. Absent on ordinary node offers — core fully
      descends an unregistered node itself, so sub-contracting there would produce the same
      mutant twice.

  The keys other than `:pipe_mode` are optional in the type because the base context
  carries only `:pipe_mode`; dispatch injects the configured options, the normalized
  configuration, and the behaviour set (and, at the sub-contract seams above, the enabled
  specs) before calling a mutator.
  """
  @type context :: %{
          :pipe_mode => pipe_mode(),
          optional(:name) => atom(),
          optional(:opts) => term(),
          optional(:config) => term(),
          optional(:behaviours) => MapSet.t(module()),
          optional(:mutators) => [Mutare.Mutator.Spec.t()],
          optional(:marks) => MapSet.t(atom())
        }

  @typedoc """
  One element of a `c:mutate/1` or `c:mutate/2` return list.

    * A bare AST node is an ordinary replacement. A top-level bare `nil` item is
      rejected because it is too easy to confuse with “no replacement”; filter
      inapplicable entries before returning the list. To replace a node with the
      literal `nil`, return `Mutare.AST.literal(nil)`.
    * A `t:Mutare.Mutator.Mutation.t/0` carries a replacement plus metadata such
      as a report note, an ignore variant, or an `:attribution` — a report-location
      override (`Mutare.Mutator.Mutation.at/2` / `at_drop/1`) for a **whole-node
      rewrite**, so a `mutate/2` that rebuilds and returns an entire registered-macro
      call is reported at the specific inner clause it changed rather than at the
      call's line (see `Mutare.Mutator.Mutation`).

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
  Parses the instance's options into its normalized configuration, once per
  resolved instance.

  Called when a `:mutators` entry is resolved to a `Mutare.Mutator.Spec` — before
  the transform reads any file — with the instance's raw options (the `opts` of a
  `{module, opts}` entry, `:as` already stripped; `[]` for a bare module). Raise
  for invalid options: this is where a typo'd option fails loudly, at startup,
  rather than on the first mutated node.

  The return value is delivered to every context-aware callback as
  `context.config` — `c:mutate/2`, the context-aware `Mutare.Mutator.Structural`
  arities, and `c:Mutare.Mutator.MacroHost.host/2`. `context.opts` continues to
  carry the raw options. A mutator without `init/1` gets
  `context.config == context.opts`.

  A module listed more than once (the documented multi-instance `:as` pattern)
  runs `init/1` once **per instance**, each call receiving that entry's own
  options. `c:Mutare.MacroRouting.route_arguments/2` is *not* config-aware: macro
  routing is shared by every mutator that meets the routed call, so its
  classification stays instance-independent by design (see `Mutare.MacroRouting`).
  """
  @callback init(opts :: term()) :: term()

  @doc """
  Declares modules that must be loadable for this mutator's routing and hosting
  to be valid.

  A DSL plugin has a deployment requirement Mutare cannot infer: the library
  whose macros it routes (`c:Mutare.MacroRouting.macro_routes/0`) or hosts
  (`c:Mutare.Mutator.MacroHost.hosted_macros/0`) must be loadable in the Mutare
  process — otherwise its routes register against nothing and its mutations
  silently fail to fire. Declaring those modules here turns the silent
  degradation into a loud startup error: the check runs once, when the
  `:mutators` entry is resolved to a `Mutare.Mutator.Spec` (before `c:init/1`,
  before any source is read), and a missing module aborts the run with a
  `Mutare.EnvironmentError` naming the plugin, the missing modules, and the
  deployment requirement.

      @impl true
      def required_modules, do: [Ecto.Schema, Ecto.Query]

  Loadability (`Code.ensure_loaded?/1`) is the whole check — it does not verify
  that a module's application is started or that its version is compatible. A
  plugin with a requirement beyond loadability raises its own descriptive error
  from `c:init/1` (or from `c:Mutare.MacroRouting.macro_routes/0`).

  A non-mutating extension may export the same function — capability discovery
  is by export, so `Mutare.Extension.validate!/1` applies the same check to
  `:extensions` entries. A module without this callback is assumed
  environment-independent.
  """
  @callback required_modules() :: [module()]

  @doc """
  Post-processes each produced mutation before it is recorded.

  Mutare applies this hook to every mutation the mutator produces, on **both** delivery
  paths — each element of a `c:mutate/1`/`c:mutate/2` return list and each element of a
  hosted target's `:mutants` (`c:Mutare.Mutator.MacroHost.host/2`) — with the same context
  the producing callback received (including `context.config`, see `c:init/1`). Return:

    * a `t:mutation/0` — the (possibly rewrapped) mutation to record;
    * `:skip` — drop this mutation.

  Because Mutare guarantees the hook runs at every delivery site, a family-rich mutator
  keeps its producers pure — return `Mutare.Mutator.Mutation.tagged(node, [family | finer])`
  everywhere — and defines the tag → filter → enrich funnel **once**: `finalize/2` reads the
  leading variant label as the family, drops mutations of disabled families (see
  `Mutare.Mutator.Families`), and attaches the family's report note. Delivery code shrinks
  to pure production, and forgetting a site cannot silently deliver unfiltered, note-less
  mutants.

  Finalization is part of production, not reporting: it runs before overlap suppression and
  `# mutare:ignore` filtering, and variant labels carried by the finalized mutation win over
  `c:variant/2` derivation exactly as at production. Two kinds of mutation are never
  finalized: a relayed mutation carrying an explicit `:producer`
  (see `Mutare.Mutator.Mutation` — it belongs to the producing family, whose own
  `finalize/2` already ran when the mutation was generated), and a
  `Mutare.Mutator.Structural` hook's bare-AST replacements (they carry no metadata to
  finalize). A target whose mutants all return `:skip` is dropped entirely.

  A mutator without `finalize/2` records mutations as returned.
  """
  @callback finalize(mutation(), context()) :: mutation() | :skip

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

  @doc """
  Asks the transform to **mark** certain argument positions of certain calls, so this mutator can
  recognise them at `c:mutate/2` and decline to mutate there (or mutate differently).

  This is the general facility behind Mutare's "don't perturb an opaque literal" behaviour: a
  mutator, not the transform, owns the knowledge of *which* positions are special. The transform
  stays domain-agnostic — it stamps `label` on the resolved position and surfaces it back as
  `context.marks` (a `MapSet` of atoms); `Mutare.Mutator.marked?/2` reads it. For example,
  `Mutare.Mutators.IntegerLiteral` marks the millisecond/`:infinity` timeout arguments of `Process.sleep`,
  `GenServer.call`, `Task.await`, `Task.async_stream`'s `:timeout` option, … and skips them, so a
  near-unkillable off-by-one on a duration is never minted.

  Called once per resolved instance (like `c:init/1`) with that instance's `config` — so a mutator
  can extend its built-in marks with positions from its own options. Return a list of declarations,
  each naming a resolved call and the positions to mark with a label:

      @impl true
      def argument_marks(config) do
        builtin() ++ Mutare.Mutator.argument_marks_from(config[:skip_arguments] || [], name())
      end

  A declaration is `{module, function, arity, positions, label}`. A `position` is an **effective**
  argument index (a piped receiver counts as index 0) or a `{:keyword, key}` for a trailing-options
  key. Arity is effective too, so an option-bearing arity (`Task.async_stream/3`, `/5`) can be
  marked while a same-named arity whose trailing argument is ordinary data (`/4`, the MFA
  callback-args list) is left alone. Marks are resolved through the same alias/import machinery as
  call matching, so aliased and imported forms are covered and a shadowing alias is not. Only the
  named value node is marked, never an enclosing container, so unrelated mutations there (e.g. `List`
  collapsing an options list) are untouched.

  Two mutators marking the same position union their labels; the label is a shared vocabulary, so a
  family can react to a label another declared (declare it too if that must survive the declarer
  being disabled). A mutator without this callback asks for no marks. `argument_marks_from/2` turns a
  user-facing `{module, function, arity, positions}` list into declarations under a label.
  """
  @callback argument_marks(config :: term()) :: [
              {module(), atom(), arity(), [non_neg_integer() | {:keyword, atom()}], atom()}
            ]

  @optional_callbacks argument_marks: 1,
                      finalize: 2,
                      init: 1,
                      mutate: 1,
                      mutate: 2,
                      mutate_call_option_keys?: 1,
                      required_modules: 0,
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
  Whether the node being offered carries the position mark `label` — i.e. sits at a position some
  mutator requested via `c:argument_marks/1`. The reader half of the marking facility: a `mutate/2`
  checks this and returns `:skip` (or adapts) at a marked position.

      def mutate(node, context) do
        if Mutare.Mutator.marked?(context, :timeout), do: :skip, else: mutate(node)
      end

  Total over a context with no marks (the common case).
  """
  @spec marked?(context(), atom()) :: boolean()
  def marked?(%{marks: marks}, label), do: MapSet.member?(marks, label)
  def marked?(_context, _label), do: false

  # The label a `:skip_arguments` mark carries until `Mutare.Transform.Resolve.ArgumentMarks` relabels
  # it with the instance's name at build — so two `:as` copies of the same module don't collide on a
  # shared module-name label.
  @self_mark :__mutare_self__

  @doc false
  @spec self_mark() :: atom()
  def self_mark, do: @self_mark

  @doc """
  Whether the offered node sits at a position *this instance* asked to leave alone via its
  `:skip_arguments` option (`skip_arguments_marks/1`). Per-instance — a second `:as` copy of the same
  module with different `:skip_arguments` is unaffected, because the mark is resolved to the
  instance's own name. Total over a context without a name (the common non-configured case).
  """
  @spec self_marked?(context()) :: boolean()
  def self_marked?(%{name: name} = context), do: marked?(context, name)
  def self_marked?(_context), do: false

  @doc """
  The `c:argument_marks/1` declarations for a configurable mutator's `:skip_arguments` option — the
  one-liner a value family uses to expose "also leave these call positions alone". Reads the
  `{module, function, arity, positions}` list from the instance's `config` and labels each with the
  per-instance self-mark that `self_marked?/1` reads back.

      def argument_marks(config), do: builtin() ++ Mutare.Mutator.skip_arguments_marks(config)
  """
  @spec skip_arguments_marks(term()) ::
          [{module(), atom(), arity(), [non_neg_integer() | {:keyword, atom()}], atom()}]
  def skip_arguments_marks(config), do: argument_marks_from(skip_entries(config), @self_mark)

  defp skip_entries(config) when is_list(config), do: Keyword.get(config, :skip_arguments, [])
  defp skip_entries(_config), do: []

  @doc """
  Turns a user-facing list of `{module, function, arity, positions}` entries into
  `c:argument_marks/1` declarations under `label`. `positions` is a list of effective argument
  indices and `{:keyword, key}` option keys, exactly as in a declaration; an index is validated
  against the declared arity. Raises `ArgumentError` with a pointed message on a malformed entry, so
  a typo fails at startup rather than silently marking nothing. For the common "leave positions from
  my `:skip_arguments` option alone" case, use `skip_arguments_marks/1` (which labels per-instance);
  reach for this directly only when you want a *shared* label other mutators may react to.
  """
  @spec argument_marks_from(term(), atom()) ::
          [{module(), atom(), arity(), [non_neg_integer() | {:keyword, atom()}], atom()}]
  def argument_marks_from(entries, label) when is_list(entries),
    do: Enum.map(entries, &marks_entry(&1, label))

  def argument_marks_from(other, _label) do
    raise ArgumentError,
          "expected a list of {module, function, arity, positions} entries, got: #{inspect(other)}"
  end

  defp marks_entry({module, fun, arity, positions} = entry, label)
       when is_atom(module) and is_atom(fun) and is_integer(arity) and arity >= 0 and
              is_list(positions) do
    Enum.each(positions, &valid_position!(&1, arity, entry))
    {module, fun, arity, positions, label}
  end

  defp marks_entry(entry, _label) do
    raise ArgumentError,
          "invalid argument-mark entry #{inspect(entry)}; expected " <>
            "{module, function, arity, positions}"
  end

  # Positions are *effective* indices, so a valid one is `0..arity-1` — a one-based typo like index
  # `3` for an arity-3 call would silently mark nothing, so reject it here.
  defp valid_position!(index, arity, _entry)
       when is_integer(index) and index >= 0 and index < arity,
       do: :ok

  defp valid_position!({:keyword, key}, _arity, _entry) when is_atom(key), do: :ok

  defp valid_position!(position, arity, entry) do
    raise ArgumentError,
          "invalid position #{inspect(position)} in #{inspect(entry)}; expected a " <>
            "0-based index below the arity #{arity}, or {:keyword, key}"
  end

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
