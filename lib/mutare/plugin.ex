defmodule Mutare.Plugin do
  @moduledoc """
  A **plugin** teaches Mutare a library's **compile-time vocabulary** — how to *resolve and
  route* the constructs the built-in mutators encounter — and **never participates in the run,
  verdict, or score**. That sentence is the whole charter; it is what decides, for years,
  whether a proposed capability belongs here:

    * **In** — *vocabulary*, all at **mutant-generation** time: macro-argument routing
      (`c:macros/0`), `use`-expansion overrides (`c:expand_use/3`), block-macro treatment,
      opaque-literal declarations — anything that changes *how source is understood and which
      mutants are generated*.
    * **Out** — *judgment*: anything that reads a run or weighs a generated mutant — coverage /
      test-selection, exonerating an equivalent survivor, adjusting the score, reporting. Those
      shape the **verdict**, so they are not plugin concerns. (A *runtime* extension point may
      host them one day; it would be a capability-named **peer** of this behaviour — like
      `Mutare.Mutator` is — not a member of a `Plugin.*` family.)

  The bright line is **vocabulary vs. judgment**, not literally compile-vs-runtime: a plugin acts
  *at* mutant generation and never *after* it. Both sides change the mutant set (a `:skip` removes
  mutants too), so "affects the score" is *not* the test — and "compile-time" alone wouldn't draw
  the line either, since statically proving a mutant equivalent is compile-time yet *judges* a
  generated mutant. The load-bearing clause is **never participates in the run, verdict, or score**.

  A plugin is **not** a `Mutare.Mutator`: it produces no mutations, is charged no slot, and never
  appears in a report — it only makes the built-in mutators' work *land* (the calls resolve, the
  right arguments are offered). A library that *also* ships custom mutators lists those separately
  under `:mutators`. A plugin contributes through two optional callbacks (a module is a usable
  plugin if loaded and exporting at least one): `c:macros/0` and `c:expand_use/3`. It is listed
  under `:plugins` (in `.mutare.exs` or `Mutare.run/2`) as a bare module **or** a `{module, opts}`
  pair — *typically* its own package (an installer like Igniter adds the one entry), but that
  third-party packaging is **incidental**: the built-in `Kernel.match?` / `destructure` routings
  are the same kind of vocabulary, just first-party.

  ## Two kinds of callback, two combination rules

  The callbacks split by *what they do*, and that split decides how multiple plugins
  combine and whether a callback sees configuration:

    * **Registration** — `c:macros/0`. Every enabled plugin's entries are **merged** into
      one registry (a later entry wins a key; see `Mutare.Macros`). A registration is a
      static declaration of *library facts* (which macros exist, how their arguments route),
      so it is **opts-independent** — it takes no context. Mirrors a mutator's
      `c:Mutare.Mutator.macros/0`.
    * **Decision / override** — `c:expand_use/3`. The enabled plugins are consulted in
      `:plugins` order and the **first** that does not `:decline` wins (`expand_use/4`). A
      decision *is* behavior, so it is **opts-aware** and **context-carrying** — it receives
      the plugin's per-instance `opts` and the caller `:module` in its `context` map (the
      same way a mutator's `opts` reach `c:Mutare.Mutator.mutate/2`, never its `macros/0`).

  In short: **registrations merge and ignore opts; decisions first-win and read opts.**

  ## The motivating case: Gettext

  `use Gettext, backend: MyApp.Gettext` injects `import Gettext.Macros`, bringing
  `gettext/1`, `ngettext/3`, … into scope as **bare calls** whose msgid arguments
  must be *compile-time literals*. Two problems compound:

    * Gettext's `__using__` registers its backend by mutating the caller module, so
      the in-process expansion in `Mutare.Transform.Uses` raises and harvests no
      directives — the `import` never becomes visible, so the bare `gettext` calls
      never resolve.
    * Even with the import visible, splicing a mutation selector into a msgid would
      poison the single build (the macro requires a literal there).

  A Gettext plugin fixes both: `c:expand_use/3` returns the `import Gettext.Macros`
  directive the failing expansion would have produced (so the calls resolve), and
  `c:macros/0` routes each macro's literal positions `:skip` while leaving the
  runtime positions (`ngettext`'s count, a bindings map) `:expression` — so those
  *are* mutated. See `Mutare.Macro.Spec` for the per-argument treatments.

  ## Per-instance options

  A `{module, opts}` entry carries `opts` (a keyword list) to the plugin, delivered to
  `c:expand_use/3` through its `t:context/0` map's `:opts` key — so a configurable plugin
  reads its parameters there. `c:macros/0` does **not** receive `opts` (a registration is a
  library fact, not behavior). Resolution is `Mutare.Plugin.Spec` (the plugin counterpart of
  `Mutare.Mutator.Spec`); a bare module is a spec with empty `opts`.
  """

  alias Mutare.Plugin.{ContractError, Expansion, Spec}

  @typedoc """
  The result of a plugin handling a `use`: a `Mutare.Plugin.Expansion` struct (the
  `import`/`alias`/`require …, as:` directives to fold in, plus any `@behaviour` modules the
  `use` injects — build it with `expand/2`), or `:decline` to fall through to the next plugin
  and then to ordinary in-process expansion.
  """
  @type expansion :: Expansion.t() | :decline

  @typedoc """
  The context map passed to `c:expand_use/3`. Carries at least:

    * `:module` — the caller module the `use` sits in (alias-resolved), so a plugin can
      reproduce a `__CALLER__.module`-dependent expansion;
    * `:opts` — the plugin's per-instance options (from a `{module, opts}` entry; `[]` for a
      bare-module entry).

  A **map on purpose** — new keys may be added in future without breaking a plugin that
  pattern-matches only the keys it needs.
  """
  @type context :: %{
          required(:module) => module(),
          required(:opts) => keyword(),
          optional(atom()) => term()
        }

  @doc """
  Override the expansion of a `use used_module, …` whose directives Mutare cannot
  (or should not) discover by in-process expansion.

  `used_module` is the alias-resolved target module (so an aliased `use G` where
  `alias Gettext, as: G` is reported as `Gettext`). `args` is the standard-quoted
  list of arguments written *after* the module — `[]` for a bare `use Gettext`,
  `[opts_ast]` for `use Gettext, backend: B` (so `args == [[backend: {:__aliases__,
  _, [:MyApp, :Gettext]}]]`). `context` is a `t:context/0` map carrying the caller
  `:module` and the plugin's `:opts`.

  Return the directives the `use` injects as a `Mutare.Plugin.Expansion` (via `expand/2`),
  which Mutare folds into resolution exactly like a harvested or inline directive, or
  `:decline` to let Mutare expand the `use` itself.

  Consulted **before** in-process expansion, so it works even when `__using__`
  raises or cannot run in the scan process. Return `:decline` to fall through — that is
  the *only* way to opt out. A handler that **raises or throws**, or returns anything other
  than an `Mutare.Plugin.Expansion`/`:decline`, is treated as a misconfigured plugin and
  surfaces **loudly** as a `Mutare.Plugin.ContractError` (it aborts the run); it is *not*
  silently coerced to `:decline`.
  """
  @callback expand_use(used_module :: module(), args :: [Macro.t()], context :: context()) ::
              expansion()

  @doc """
  Known-macro registrations contributed by this plugin — the same declarative
  entries a mutator's `c:Mutare.Mutator.macros/0` returns
  (`{module, name, arity, treatment}` / `{module, name, treatment}`; see
  `Mutare.Macros` and `Mutare.Macro.Spec`). Merged into the transform's macro
  registry when the plugin is enabled. A registration is a static library fact, so it
  receives no options — a plugin needing configuration reads it in `c:expand_use/3`.
  """
  @callback macros() :: [tuple()]

  @optional_callbacks expand_use: 3, macros: 0

  # The callbacks that make a module a plugin — a module exporting any of these is a
  # usable `:plugins` entry (so a macros-only or use-only plugin both qualify).
  @plugin_callbacks [expand_use: 3, macros: 0]

  @doc """
  Build a `Mutare.Plugin.Expansion` from the `directives` a `use` injects (and optionally the
  `@behaviour` `behaviours`) — the constructor a plugin returns from `c:expand_use/3` instead
  of writing the struct out. `directives` are standard-quoted AST (e.g. from `quote/2`);
  `behaviours` are module atoms.
  """
  @spec expand([Macro.t()], [module()]) :: Expansion.t()
  def expand(directives, behaviours \\ [])

  def expand(directives, behaviours) when is_list(directives) and is_list(behaviours),
    do: %Expansion{directives: directives, behaviours: behaviours}

  # A non-list argument is a contract violation (a plugin passed a bare directive/behaviour rather
  # than a list — `quote do … end` returns a *single* node, not a list). Raise `ContractError` —
  # loud, like a malformed `expand_use/3` return — rather than a `FunctionClauseError` that
  # `safe_expand/4` would swallow to a silent `:decline`, leaving the plugin mysteriously inert.
  def expand(directives, behaviours) do
    raise ContractError,
      message:
        "Mutare.Plugin.expand/2 expects a list of directives and a list of behaviours, got: " <>
          "directives=#{inspect(directives)}, behaviours=#{inspect(behaviours)}"
  end

  @doc """
  Whether `module` is a usable plugin: loaded, exporting at least one plugin callback
  (`expand_use/3` or `macros/0`), and **not** itself a `Mutare.Mutator`. Used to validate the
  `:plugins` option.

  The mutator exclusion matters because a *macro-aware* mutator exports `macros/0` too: without
  it, listing a mutator under `:plugins` would pass validation, silently merge its macro routing,
  yet never run its mutations (a plugin is charged no slot). A mutator's macro registrations reach
  the registry through `:mutators`; `:plugins` is for non-mutating extensions only.
  """
  @spec plugin?(term()) :: boolean()
  def plugin?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and not mutator?(module) and
      Enum.any?(@plugin_callbacks, fn {fun, arity} -> function_exported?(module, fun, arity) end)
  end

  def plugin?(_other), do: false

  # A `Mutare.Mutator` is never a plugin — not even one that ships a `macros/0` registration (a
  # macro-aware mutator does). Detected by the declared `@behaviour Mutare.Mutator`, so a plain
  # `macros/0` exporter that is *not* a mutator still qualifies. Run only after `plugin?/1`'s
  # `Code.ensure_loaded?`, so the attribute is available; any reflection slip degrades to "not a
  # mutator" (the module is then judged on its callbacks alone).
  defp mutator?(module) do
    declared = module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    Mutare.Mutator in declared
  rescue
    _ -> false
  end

  @doc """
  Validate and **resolve** a `:plugins` list to `Mutare.Plugin.Spec`s — accepting a bare
  plugin module or a `{module, opts}` pair (or an already-resolved `Spec`, idempotent) and
  raising `ArgumentError` on a non-list, a malformed entry, or a module that is not a loaded
  plugin (`plugin?/1`).

  The single home for the `:plugins` check, called both at the `Mutare.Options` boundary and
  by `Mutare.Transform.transform_string/2` — so a mistyped or non-plugin module **fails
  loudly** rather than being silently dropped by the per-callback filters (`use_handlers/1`,
  `Mutare.Macros.from_plugins/1`).
  """
  @spec validate!(term()) :: [Spec.t()]
  def validate!(plugins) when is_list(plugins), do: Enum.map(plugins, &validate_entry!/1)

  def validate!(other) do
    raise ArgumentError,
          ":plugins must be a list of plugin modules or {module, opts} pairs, got: #{inspect(other)}"
  end

  # `Mutare.Plugin.Spec.new/1` is the single home for the *shape* dispatch (bare module,
  # `{module, opts}`, an already-resolved `Spec`, or a raise on anything else), so resolving the
  # entry through it — rather than re-listing the same four clauses here — keeps the accepted shapes
  # defined in one place. `ensure_plugin!/1` then adds the *semantic* checks (opts is a keyword
  # list; the module is a loaded plugin) that `Spec.new/1`, a pure shape resolver, deliberately
  # doesn't make.
  defp validate_entry!(entry), do: entry |> Spec.new() |> ensure_plugin!()

  defp ensure_plugin!(%Spec{module: module, opts: opts} = spec) do
    # A `%Spec{}` can reach here hand-built (the `Mutare.run/2` path re-validates the resolved
    # specs `Mutare.Options` already produced), bypassing the `{module, opts}` shape guard, so the
    # keyword-opts invariant is re-checked here — else a `%Spec{opts: :garbage}`, or a non-keyword
    # list like `[:a, :b]`, would pass and a plugin reading `context.opts` would silently see no
    # options (`Keyword.get/Access` treat a non-keyword list as empty rather than raising).
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            ":plugins entry opts must be a keyword list, got: #{inspect(opts)} (for #{inspect(module)})"
    end

    unless plugin?(module) do
      raise ArgumentError,
            ":plugins entries must be loaded modules implementing Mutare.Plugin " <>
              "(exporting expand_use/3 or macros/0), got: #{inspect(module)}"
    end

    spec
  end

  @doc """
  The subset of `plugins` that override `use` expansion (export `expand_use/3`), as resolved
  `Mutare.Plugin.Spec`s. `Mutare.Transform.Uses` threads the result through its walk and
  consults it at each module-level `use`. Accepts bare modules or specs (normalized via
  `Mutare.Plugin.Spec.new/1`) and ensures each module is loaded first, so the filter holds
  regardless of whether the module has been referenced yet (`function_exported?/3` is `false`
  for a not-yet-loaded module).
  """
  @spec use_handlers([Spec.t() | module() | {module(), keyword()}]) :: [Spec.t()]
  def use_handlers(plugins) when is_list(plugins) do
    plugins
    |> Enum.map(&Spec.new/1)
    |> Enum.filter(fn %Spec{module: m} ->
      Code.ensure_loaded?(m) and function_exported?(m, :expand_use, 3)
    end)
  end

  @doc """
  Resolve a `use used, args` against the ordered `handlers` (from `use_handlers/1`): the first
  handler that does not `:decline` wins, returning its `t:expansion/0`; `:decline` when every
  handler declines (or there are none).

  `context` carries the caller `:module`; this function adds **each handler's own `:opts`**
  before invoking it, so the plugin sees `%{module: …, opts: …}`. A handler can never hijack
  another's result — only `:decline` falls through to the next. But a **misbehaving** handler is
  loud, not isolated: a handler that **raises or throws**, or returns a value that is neither a
  `Mutare.Plugin.Expansion` nor `:decline`, is a broken/misconfigured plugin (not a target
  property), so it surfaces as a `Mutare.Plugin.ContractError` (see `safe_expand/4`) rather than
  degrading. That `ContractError` rides through `Mutare.Transform.Uses.Harvest`'s never-raise
  boundary — which exists to absorb the *target*'s un-expandable `use`s, not a plugin's bugs — up
  to `Mutare.Schema`.

  Handlers may be `Mutare.Plugin.Spec`s (the production caller `use_handlers/1` passes those) or
  raw entries (a bare module / `{module, opts}` pair) — both are normalized through `Spec.new/1`.
  """
  @spec expand_use([Spec.t() | module() | {module(), keyword()}], module(), [Macro.t()], map()) ::
          expansion()
  def expand_use(handlers, used, args, context) when is_list(handlers) do
    handlers
    |> Enum.map(&Spec.new/1)
    |> Enum.find_value(:decline, fn %Spec{module: module, opts: opts} ->
      case safe_expand(module, used, args, Map.put(context, :opts, opts)) do
        # `:decline` → keep looking. An `%Expansion{}` (even an empty one — a deliberate
        # "handle and inject nothing") wins: first-non-`:decline` wins. A handler that wants to
        # fall through must return `:decline`, not `Mutare.Plugin.expand([])`.
        :decline -> nil
        %Expansion{} = expansion -> expansion
      end
    end)
  end

  # Invoke one handler, classifying its outcome. **Any** misbehavior is loud — a plugin bug is a
  # *misconfiguration* (the user installed a broken plugin), never a property of the target being
  # scanned, so none of it is swallowed:
  #
  #   * a *contract* violation — a return that is neither `%Expansion{}` nor `:decline` — raises
  #     `Mutare.Plugin.ContractError` directly;
  #   * a *raise*, or a *throw/exit*, from `expand_use/3` is **wrapped** in
  #     `Mutare.Plugin.ContractError` (the original cause kept in the message, the original
  #     stacktrace preserved) so it, too, surfaces as a `ContractError`.
  #
  # `ContractError` is the one type `Mutare.Transform.Uses.Harvest`'s never-raise boundary re-raises
  # (`e in ContractError -> reraise`) while still swallowing the *target*-expansion failures it is
  # designed to absorb — so a plugin bug rides *through* that boundary up to `Mutare.Schema` and
  # surfaces loudly, instead of silently dropping directives. Only `:decline` falls through to the
  # next handler. (`Mutare.Plugin.expand/2`'s own non-list `ContractError` is raised *inside*
  # `expand_use/3`, so it arrives here as a `ContractError` and the first clause re-raises it intact.)
  defp safe_expand(module, used, args, context) do
    case module.expand_use(used, args, context) do
      :decline -> :decline
      %Expansion{} = expansion -> expansion
      other -> raise ContractError, message: contract_message(module, other)
    end
  rescue
    e in ContractError -> reraise e, __STACKTRACE__
    other -> reraise ContractError, [message: raised_message(module, other)], __STACKTRACE__
  catch
    kind, value ->
      reraise ContractError, [message: thrown_message(module, kind, value)], __STACKTRACE__
  end

  defp contract_message(module, other) do
    "plugin #{inspect(module)} returned an invalid result from expand_use/3: #{inspect(other)} — " <>
      "expected a Mutare.Plugin.Expansion (build it with Mutare.Plugin.expand/2) or :decline"
  end

  defp raised_message(module, error) do
    "plugin #{inspect(module)} raised in expand_use/3 (#{inspect(error.__struct__)}): " <>
      "#{Exception.message(error)} — a plugin must return a Mutare.Plugin.Expansion " <>
      "(build it with Mutare.Plugin.expand/2) or :decline, not raise"
  end

  defp thrown_message(module, :throw, value),
    do:
      "plugin #{inspect(module)} threw #{inspect(value)} in expand_use/3 — expected a " <>
        "Mutare.Plugin.Expansion or :decline"

  defp thrown_message(module, kind, value),
    do:
      "plugin #{inspect(module)} signalled #{kind} #{inspect(value)} in expand_use/3 — expected a " <>
        "Mutare.Plugin.Expansion or :decline"
end
