defmodule Mutare.Transform.Resolve do
  @moduledoc false
  # The unified lexical name-resolution pre-pass: one walk over the parsed (Sourceror) AST
  # that threads a single scoped environment and stamps every call with the module it refers
  # to, so the call-matching mutator families recognise it. It is the driver; the *rules*
  # live in two cohesive vocabulary modules — `Mutare.Transform.Aliases` (for `alias`,
  # stamping a remote call's `__aliases__` module node) and `Mutare.Transform.Imports` (for
  # `import`, stamping a bare call). `Mutare.Transform.Calls.resolved_call/1` is the reader
  # both feed.
  #
  # ## Why one walk (aliases and imports interleave)
  #
  # `alias` and `import` share one lexical scope and must be folded *together*, in source
  # order, because they interact:
  #
  #     import Foo.B    # imports the module Foo.B
  #     alias A.B       # now the name `B` resolves to A.B
  #     import B        # imports A.B (the alias is in force) — a *different* module
  #
  # A single left-to-right fold over each statement sequence gets this right by construction:
  # `register/2` extends the alias env (via `Aliases.register`) *and* the import env (via
  # `Imports.register`, which resolves its module path through the alias env in force) at each
  # statement, and each statement is walked under the env established by its predecessors.
  # Nested scopes inherit (the env passes *down* into children); a child's additions don't
  # leak back out (`map_reduce` discards the threaded env). This is also why there is one walk
  # rather than two passes: a second pass would rebuild the same alias env to resolve imports.
  #
  # The env: `aliases` (the alias map), `imports` (`%{module_path => selector}`), `kernel`
  # (the tracked `Kernel` selector, default `:all`), and `module` (the enclosing module, `nil` at the top level — the one piece of module
  # scope this pass tracks, so `Mutare.Transform.ModuleScope` can fold the implicit alias a nested
  # `defmodule` introduces; a call to a sibling nested module by short name then resolves to the
  # module Elixir defines, matching a `:call_routes` entry keyed on it). Bare function captures
  # (`&fun/N`) are not calls syntactically, but when
  # `fun/N` resolves to an import they get the same import stamp a synthesized `fun(args…)` probe
  # needs for capture mutation.

  alias Mutare.CallRouting.Registry, as: Routes
  alias Mutare.CallRouting.Registry.Entry
  alias Mutare.CallRouting.Spec
  alias Mutare.Transform.{Aliases, Imports, Meta, MetaKeys, ModuleScope, QuoteStructure, Uses}
  alias Mutare.Transform.WrittenPipe
  alias Mutare.Transform.Resolve.{ArgumentMarks, Arguments, NodeIds, OperandPositions, RouteStamp}
  alias Mutare.Transform.StructuralForms

  @doc "Stamp remote calls, bare imported calls, and bare imported captures with their resolved module."
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast), do: annotate(ast, %Routes{routes: %{}, hosts: []})

  @doc """
  As `annotate/1`, plus stamp each call that resolves to a **known macro** (in the
  `registry` built by `Mutare.CallRouting.Registry.build/3`) with its per-argument routing under
  `meta[:mutare_route]`, so the analyzer routes a pattern/opaque argument correctly
  instead of mutating it. The registry is carried in the env (read-only) and
  consulted at each remote and bare call.

  `opts` carries the pass's diagnostics wiring: `:warnings` (default `true`) gates the
  advisory classifier warnings `RouteStamp` may print, and `:file` labels them. The
  transform's two-phase callers disable warnings on re-runs of the same source so each
  is printed once (see `Mutare.Transform`'s `:warnings` option).
  """
  @spec annotate(Macro.t(), Routes.registry(), keyword()) :: Macro.t()
  def annotate(ast, registry, opts \\ []) do
    ast
    |> NodeIds.stamp()
    |> OperandPositions.stamp()
    |> walk(%{
      aliases: %{},
      imports: %{},
      kernel: Imports.default_selector(),
      # The enclosing module (`nil` at the file top level), threaded so `ModuleScope` can fold the
      # implicit alias Elixir introduces for a nested module — a sibling nested module referred to
      # by short name then resolves to what the compiler defines (`Outer.Foo`, not the bare `Foo`).
      module: nil,
      call_routes: registry,
      marks: Keyword.get(opts, :marks, ArgumentMarks.empty()),
      on_resolve: Keyword.get(opts, :on_resolve, fn _ast -> :ok end),
      diag: %{
        warn?: Keyword.get(opts, :warnings, true),
        file: Keyword.get(opts, :file, "nofile")
      }
    })
  end

  # A routed call retains its lexical environment for a host's explicit re-entry into Elixir.
  # Foreign syntax itself is never walked: even an `alias` or `import` inside it belongs to
  # the DSL. Islands start in the environment at the enclosing call, then scope normally.
  @doc false
  @spec context(Macro.t(), map()) :: map()
  def context({_head, meta, _args}, context) do
    case Keyword.fetch(meta, MetaKeys.resolution_key()) do
      {:ok, env} -> Map.put(context, :resolution, env)
      :error -> context
    end
  end

  # Resolve a region in the environment a routed call retained: what `Mutare.Analyze` runs
  # ahead of an island's analysis (`expression_mutations/3`), and offers a host on its own
  # as `Mutare.Analyze.resolve/2` for the calls its DSL embeds.
  @doc false
  @spec expression(Macro.t(), map()) :: Macro.t()
  def expression(subtree, %{resolution: env}) do
    resolved = walk(subtree, env)
    env.on_resolve.(resolved)
    resolved
  end

  def expression(subtree, _context), do: subtree

  # Readers of preserved expressions need local directives in source order, without
  # resolving calls, expanding uses, or invoking classifiers inside the boundary.
  @doc false
  @spec advance_context(Macro.t(), map()) :: map()
  def advance_context(stmt, %{resolution: env} = context) do
    aliases = Aliases.register(stmt, env.aliases)
    {imports, kernel} = Imports.register(stmt, aliases, env.imports, env.kernel)
    %{context | resolution: %{env | aliases: aliases, imports: imports, kernel: kernel}}
  end

  def advance_context(_stmt, context), do: context

  # Relocation and binding analysis must recognize preserved Kernel stages without
  # resolving the surrounding syntax or invoking its classifiers. Read only the operator
  # identity from the boundary's retained environment, advanced by local directives.
  @doc false
  @spec kernel_pipe?(Macro.t(), map()) :: boolean()
  def kernel_pipe?({:|>, meta, args}, %{resolution: env}) do
    {_meta, module_key} = resolve_pipe_call(meta, args, env)
    module_key == [:Kernel]
  end

  def kernel_pipe?(pipe, _context), do: Mutare.Transform.Calls.kernel_call?(pipe)

  # The `Kernel` form a call is, read as `Calls.kernel_form/1` reads a stamped one — by
  # identity, so `Kernel.if` and `K.if` are `:if` — and, for a call this pass did not walk
  # (inside a skipped call's argument), through the boundary's retained environment. Such a
  # call carries no stamp, and its spelling says nothing: a displaced `if/2` would read as
  # Kernel's conditional, an aliased `K.if` or absolute `Elixir.Kernel.if` as another
  # module's function, a `Kernel.if` under `alias Other, as: Kernel` as Kernel's. That
  # `Calls.resolved_call/1` answers is no evidence of a stamp either — it reads any
  # `Mod.fun` receiver's literal path where no stamp says otherwise — so the identity is
  # `preserved_identity/4`'s, which takes a stamp where there is one and resolves the
  # written name where there is none. `nil` for any other call.
  @doc false
  @spec kernel_form(Macro.t(), map()) :: atom() | nil
  def kernel_form({form, meta, args}, %{resolution: env})
      when is_list(meta) and is_list(args) do
    case preserved_identity(form, meta, args, env) do
      {[:Kernel], fun} -> fun
      _other -> nil
    end
  end

  def kernel_form(node, _context), do: Mutare.Transform.Calls.kernel_form(node)

  # A read-only effective call for binding analysis. The preserved source is not
  # rewritten or routed. Grouped RHS nodes are stages, just as in Kernel's expansion.
  @doc false
  @spec preserved_pipe_call(Macro.t(), map()) :: Macro.t() | nil
  def preserved_pipe_call({:|>, meta, [left, right]} = pipe, context) do
    if kernel_pipe?(pipe, context) do
      case right do
        {:|>, _, [_, _]} ->
          preserved_pipe_call(WrittenPipe.flatten_right(meta, left, right), context)

        _ ->
          direct_call(left, right)
      end
    end
  end

  # A read-only route for a call in a preserved region — an argument of a skipped call, which
  # this pass did not walk — so the binding readers (`Mutare.Transform.BindingEscapeEmit`,
  # `Mutare.Transform.Bindings`) can read its declared positions: skip withholds mutation and
  # nested routing, not evaluation, and `destructure/2` binds under a skipped wrapper as it
  # does anywhere — skipped itself or not. The call's identity is resolved through the
  # boundary's retained environment, advanced by local directives, and its meaning read from
  # the registry exactly as `RouteStamp` reads a stamped skip's; only a **static** route
  # answers. A `:routing` classifier is never invoked in a
  # region it was withheld from, and its call reads as `:unknown` — not as unrouted: a
  # declared route whose positions were not obtained may bind names the readers cannot see,
  # so an enclosing binding-sensitive delivery withholds rather than assumes
  # (`Bindings.unknown_routing?/1`, `Candidate.Delivery.gate/2`), and the scope beside and
  # after the call counts every name its arguments mention as a possible write
  # (`Bindings.matched_names/1`). The same answer serves a call inside a `:raw`/`:hosted`
  # position, which this pass did not walk either; there the enclosing route declared the
  # region syntax, and `Bindings` reads `:unknown` as possible writes alone. Nothing is
  # stamped or rewritten. A stamped call answers from its stamp (`Meta.routing/1`) and never
  # reaches here.
  @doc false
  @spec preserved_routing(Macro.t(), map()) :: :skip | :unknown | [Spec.position()] | nil
  def preserved_routing({form, meta, args}, %{resolution: env})
      when is_list(meta) and is_list(args) do
    case preserved_identity(form, meta, args, env) do
      nil -> nil
      {module_key, fun} -> static_routing(module_key, fun, length(args), env)
    end
  end

  def preserved_routing(_node, _context), do: nil

  # The route the binding readers read a call's arguments by — what the arguments *mean*, as
  # distinct from whether they mutate. A stamped call answers from its stamp; a stamped `:skip`
  # from the declaration the configured skip displaced (`Meta.displaced_routing/1`: positions,
  # or `:unknown`), else as the ordinary call a skip leaves it; an unstamped call — inside a
  # skipped call's argument — from `preserved_routing/2`. "Do not mutate this call" never
  # means "forget what its arguments mean": `destructure/2` binds its pattern skipped or not,
  # and `match?/2`'s pattern binds nothing either way.
  @doc false
  @spec effective_routing(Macro.t(), map()) :: :skip | :unknown | [Spec.position()] | nil
  def effective_routing({_form, meta, _args} = node, context) when is_list(meta) do
    case Meta.routing(meta) do
      nil -> preserved_routing(node, context)
      :skip -> Meta.displaced_routing(meta) || :skip
      routing -> routing
    end
  end

  def effective_routing(_node, _context), do: nil

  # A call's identity through the retained environment: a stamp where the call has one (a
  # walked call under a routed position — `kernel_form/2` asks for those too), the written
  # name resolved in that environment where it has none.
  defp preserved_identity(
         {:., _dot_meta, [{:__aliases__, alias_meta, path}, fun]},
         _meta,
         _args,
         env
       )
       when is_atom(fun),
       do: {Aliases.resolved_module(alias_meta, Aliases.resolve_path(path, env.aliases)), fun}

  defp preserved_identity({:., _dot_meta, [mod, fun]}, _meta, _args, _env) when is_atom(fun) do
    case Aliases.resolve_node(mod, %{}) do
      nil -> nil
      module_key -> {module_key, fun}
    end
  end

  defp preserved_identity(fun, meta, args, env) when is_atom(fun) do
    meta = Imports.stamp(fun, meta, args, env.imports, env.kernel)
    {bare_module_key(fun, length(args), meta, env), fun}
  end

  defp preserved_identity(_form, _meta, _args, _env), do: nil

  # The one reading a stamped skip is stamped with (`RouteStamp.declared_routing/4`): a call
  # preserved beneath a skipped call, and the skipped call itself, read the same declaration —
  # `hd(destructure([n], [8]))` with both skipped binds `n` as it does with either.
  defp static_routing(module_key, fun, arity, env),
    do: RouteStamp.declared_routing(env.call_routes, module_key, fun, arity)

  @doc false
  @spec forget(Macro.t()) :: Macro.t()
  def forget(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} ->
        # mutare:ignore[keyword_delete] equivalent — only ever `Keyword.put`, so it occurs once
        {form, Keyword.delete(meta, MetaKeys.resolution_key()), args}

      node ->
        node
    end)
  end

  @doc """
  The stable node id stamped by the pre-pass, or `nil` for a node carrying no metadata
  (a bare atom — an operator/function-name — or a list — an argument list). Those two
  shapes never receive a nid, which is exactly why `Mutare.Transform.Overlap` treats an
  operator-swap / function-rename / arity-change footprint as non-covering for free.
  """
  @spec nid(Macro.t()) :: non_neg_integer() | nil
  def nid(node), do: NodeIds.get(node)

  # A statement sequence: fold the env left-to-right so an `alias`/`import` extends it for the
  # *subsequent* siblings only. Each statement is walked under the env in force *before* it
  # (so a directive resolves nothing on its own line, and order is textual).
  defp walk({:__block__, meta, stmts}, env) when is_list(stmts) do
    {walked, _env} =
      Enum.map_reduce(stmts, env, fn stmt, env ->
        {walk(stmt, env), register(stmt, env)}
      end)

    {:__block__, meta, walked}
  end

  # A `quote` body is quoted data, not a lexical child scope in the source being transformed.
  # Walk only live quote parts: option values (evaluated where the quote expression runs) and
  # escaping `unquote`/`unquote_splicing` arguments in the quoted block, resolving them under the
  # env at the quote site. That keeps a quoted directive such as `alias List, as: S` from
  # restamping `unquote(S.trim(s))`, whose expression is evaluated in the outer scope.
  defp walk({:quote, meta, args}, env) when is_list(args) do
    # The head (`Kernel.SpecialForms.quote`) is stamped like any bare call, so a `:skip` route on
    # it is honoured — the analyzer then leaves the whole quote alone, escaping unquotes included.
    {meta, _module_key} = stamp_bare_call(:quote, meta, args, env)

    {:quote, meta,
     if(Meta.routing(meta) == :skip, do: args, else: walk_live_quote_args(args, env))}
  end

  # `left |> stage(args)` is sugar for `stage(left, args)`, and from here on it *is* that call —
  # `Kernel.|>/2`'s own desugaring (`direct_stage/4`). Nothing in this pass, or after it, knows a
  # call "one argument short": the stage's arity, import, route and argument marks all come out
  # of the clauses that serve a written call, with the left side as argument 0, and every later
  # reader of ordinary Elixir finds the one shape. Routes withhold foreign syntax before descent.
  # That the user wrote a pipe is kept as the operator's meta on the call
  # (`Mutare.Transform.WrittenPipe`), which is what a Site and the rendered metamutant spell it
  # back from.
  #
  # That holds for `Kernel.|>/2` alone. A `|>` displaced out of `Kernel`
  # (`import Kernel, except: [|>: 2]` beside a custom operator) is somebody else's macro or
  # function: whether its right side receives the left as an argument is that definition's
  # business, so the node takes the generic bare-call walk, with the whole routing vocabulary
  # open to it (its head resolves to a `:call`, not the structural `Kernel` pipe).
  # `Mutare.Transform.Calls.kernel_call?/1` is how every later reader of a `|>` node asks the
  # same question.
  defp walk({:|>, meta, [lhs, rhs] = args}, env) do
    {resolved_meta, module_key} = resolve_pipe_call(meta, args, env)

    if module_key != [:Kernel] do
      walk_bare_call(:|>, resolved_meta, module_key, args, env)
    else
      meta = stamp_routed(resolved_meta, module_key, :|>, args, env)

      cond do
        Meta.routing(meta) == :skip ->
          {:|>, meta, args}

        match?({:|>, _, [_, _]}, rhs) ->
          # Kernel flattens grouped right-hand stages before expanding the pipe.
          walk(WrittenPipe.flatten_right(meta, lhs, rhs), env)

        true ->
          direct_stage(meta, lhs, rhs, env) || {:|>, meta, descend(args, env)}
      end
    end
  end

  # A bare function-reference capture `&fun/N` is a call value, but the ref node is
  # `{fun, meta, context}`, not a bare call `{fun, meta, args}`, so the ordinary bare-call
  # clause below never sees it. Stamp the ref with the import metadata a synthesized N-ary
  # `fun(v1, …, vN)` probe would get. The analyzer still decides whether the surrounding
  # runtime context may mutate it; this pass only records lexical resolution.
  #
  # If the right side is not a literal arity, this is an expression capture/body division
  # (`&foo / bar`), not `&fun/N`; fall back to normal descent so `/` remains mutatable there.
  defp walk({:&, amp_meta, [{:/, slash_meta, [{fun, ref_meta, context} = ref, right]}]}, env)
       when is_atom(fun) and is_list(ref_meta) and is_atom(context) do
    # The capture head (`Kernel.SpecialForms.&`) is stamped like any bare call, so a `:skip` route
    # on it is honoured here too (the other `&` shapes reach the bare-call clause on their own).
    {amp_meta, _module_key} =
      stamp_bare_call(:&, amp_meta, [{:/, slash_meta, [ref, right]}], env)

    case capture_arity(right) do
      {:ok, arity} ->
        ref_meta =
          Imports.stamp(fun, ref_meta, placeholder_args(arity), env.imports, env.kernel)

        amp_meta = copy_import_witness(amp_meta, ref_meta)
        {:&, amp_meta, [{:/, slash_meta, [{fun, ref_meta, context}, right]}]}

      :error ->
        {:&, amp_meta, [walk({:/, slash_meta, [ref, right]}, env)]}
    end
  end

  # A remote call `Mod.fun(...)`: stamp its module position with the alias-resolved module
  # (and, when it resolves to a known macro, its argument routing on the call meta), then
  # descend the arguments (they may contain bare imported calls).
  defp walk({{:., dot_meta, [{:__aliases__, _am, path} = aliases, fun]}, call_meta, args}, env)
       when is_list(args) do
    stamped = Aliases.stamp_module(aliases, env.aliases)
    module_key = Aliases.resolve_path(path, env.aliases)
    call_node = {{:., dot_meta, [stamped, fun]}, call_meta, args}

    call_meta = RouteStamp.stamp(call_meta, module_key, fun, args, call_node, env)
    call_meta = stamp_mark_call(call_meta, module_key, fun, args, env)
    call_meta = retain_environment(call_meta, env)
    walked = descend_marked(args, module_key, fun, call_meta, env)
    {{:., dot_meta, [stamped, fun]}, call_meta, walked}
  end

  # A direct Erlang/atom-module remote call `:mod.fun(...)`: the receiver is a bare (or Sourceror-
  # wrapped) atom — never alias-stamped, so the atom *is* the module key. (An *aliased* atom module
  # `alias :binary, as: B; B.fun(...)` is the `__aliases__` shape above, resolved via the alias env.)
  # `Aliases.resolve_node/2` is consulted **env-free** (`%{}`), exactly as
  # `Mutare.Transform.Calls.resolved_call/1`'s twin clause: the `__aliases__` (Elixir) shape was
  # handled above, so only bare/wrapped-atom (and non-module) receivers reach here, none of which
  # consult the alias env — passing it would be misleading dead input.
  #
  # The receiver splits the two cases cleanly: a non-nil result is a genuine **atom module**, so the
  # call is stamped with its known-macro routing (the module side stays opaque, never walked — same
  # as `Mod.fun`'s `__aliases__` above) — bringing the macro path level with `resolved_call/1`. A
  # `nil` result means the receiver is *not* a module reference but a **runtime sub-expression** — a
  # chained call (`get_config().fetch(k)`, `Repo.get(...).name`), a variable/result dispatch
  # (`obj.fun(...)`), and so on — so it is **walked** (in the same lexical scope), letting
  # an aliased/imported/known-macro call sitting in the receiver get its stamp instead of being
  # silently skipped (the old generic-clause behaviour). The function-name atom `fun` is never
  # touched. (Analyze mirrors this split — `descend_receiver/2` — so such a receiver is also offered
  # to mutators.)
  defp walk({{:., dot_meta, [mod, fun]}, call_meta, args}, env)
       when is_atom(fun) and is_list(args) do
    case Aliases.resolve_node(mod, %{}) do
      nil ->
        walked = walk(mod, env)
        {{:., dot_meta, [walked, fun]}, call_meta, descend(args, env)}

      module_key ->
        call_node = {{:., dot_meta, [mod, fun]}, call_meta, args}
        call_meta = RouteStamp.stamp(call_meta, module_key, fun, args, call_node, env)
        call_meta = stamp_mark_call(call_meta, module_key, fun, args, env)
        call_meta = retain_environment(call_meta, env)
        walked = descend_marked(args, module_key, fun, call_meta, env)
        {{:., dot_meta, [mod, fun]}, call_meta, walked}
    end
  end

  # An **anonymous call** `callee.(args)` (`f.(x)`, `(fn … end).(x)`): the one-element dot head has
  # no function name and its callee is never a module reference, so walk it like the non-module
  # receiver above — an aliased/imported/known-macro call inside an immediately-invoked `fn` gets its
  # stamp. (Analyze's `descend_receiver/2` has the matching clause.)
  defp walk({{:., dot_meta, [callee]}, call_meta, args}, env) when is_list(args) do
    {{:., dot_meta, [walk(callee, env)]}, call_meta, descend(args, env)}
  end

  # A `defmodule … do … end`: stamp the head (an `__aliases__` head with its resolved module — the
  # same `:mutare_alias` contract as a remote call's — so `Mutare.Lifting.module_from_alias/2` can
  # resolve a top-level aliased head like `alias Real.Parent, as: RP; defmodule RP.Child`; a dynamic
  # head is *walked* so its interior calls resolve), then — **only for a genuine `Kernel.defmodule`**
  # — open the module scope its body is walked under: the module entered (`ModuleScope.child_module/3`,
  # the unresolved sentinel for a non-static head like `__MODULE__.Sub`, under which nested modules
  # stay unresolved rather than resolve against the enclosing module) plus the in-body self-alias the
  # head introduces. A **displaced** `defmodule` (a DSL macro imported over Kernel's — `import Kernel,
  # except: [defmodule: 2]` + `import MyDSL, only: [defmodule: 2]`) defines no module named after its
  # head, so it opens NO scope: treating its `do` block as an Elixir module body would resolve/route
  # interior calls against a module that needn't exist. Must precede the bare-call clause below.
  defp walk({:defmodule, meta, [head, body] = args}, env) when is_list(body) do
    {meta, module_key} = stamp_bare_call(:defmodule, meta, args, env)

    if kernel_module_definer?(:defmodule, meta, args, env) do
      {:defmodule, meta, [defmodule_head(head, env), walk(body, module_body_env(head, env))]}
    else
      {:defmodule, meta, descend_marked(args, module_key, :defmodule, meta, env)}
    end
  end

  # `defimpl P, for: T` opens the **impl module** scope `P.T` (absolute — never parent-prefixed), so
  # its body must be walked under `P.T`, not the enclosing module (which would resolve/route a nested
  # module or call inside the impl against the wrong one). Handles all three surface forms —
  # `defimpl P, for: T do … end` (`[proto, opts, do-block]`), the inline `defimpl P, for: T, do: …`
  # (`[proto, [for: …, do: …]]`), and `defimpl P do … end`/`P, do: …` (`for:` inferred → unresolved) —
  # by scoping only the **last** argument (which always holds the `do` block) to `P.T` and walking the
  # rest (proto, a standalone `for:`) in the enclosing scope; a standalone `for:` value is a module
  # reference, so putting the inline form's `for:` under `P.T` too is harmless (walk never stamps a
  # bare `__aliases__`). Gated on the call still resolving to `Kernel.defimpl` (like the `defmodule`
  # gate): a displaced `defimpl` (a DSL macro over Kernel's) defines no `P.T`, so it falls back to
  # ordinary traversal in the enclosing scope. Must precede the bare-call clause.
  #
  # A genuine `defimpl` is also stamped with the impl module it opens (`:mutare_impl_module` — the
  # sentinel when unresolved), which is what tells `Mutare.Transform` to plan its body as a module
  # body (lifting guards/head literals/clause structure under that module's `:skip_lifting` name)
  # rather than analyze it in place like any other statement. The stamp's *presence* is the
  # "this is Kernel's `defimpl`" signal; a displaced one carries none and stays an expression.
  defp walk({:defimpl, meta, args}, env) when is_list(args) and length(args) >= 2 do
    {meta, module_key} = stamp_bare_call(:defimpl, meta, args, env)

    if kernel_module_definer?(:defimpl, meta, args, env) do
      impl = ModuleScope.impl_module(hd(args), defimpl_for_type(args), env.aliases)
      {lead, [last]} = Enum.split(args, -1)
      walked = Enum.map(lead, &walk(&1, env)) ++ [walk(last, %{env | module: impl})]
      {:defimpl, Keyword.put(meta, MetaKeys.impl_module_key(), impl), walked}
    else
      {:defimpl, meta, descend_marked(args, module_key, :defimpl, meta, env)}
    end
  end

  # A bare call `fun(...)`: stamp it with its resolved import (or Kernel-displacement), then —
  # when it resolves to a known macro — its argument routing, then descend the arguments.
  defp walk({fun, meta, args}, env) when is_atom(fun) and is_list(args) do
    {meta, module_key} = resolve_bare_call(fun, meta, args, env)
    walk_bare_call(fun, meta, module_key, args, env)
  end

  # Any other n-ary node (`__aliases__`, operators with a tuple form, …): nothing to stamp —
  # descend the arguments.
  defp walk({form, meta, args}, env) when is_list(args), do: {form, meta, descend(args, env)}

  defp walk({left, right}, env), do: {walk(left, env), walk(right, env)}
  defp walk(list, env) when is_list(list), do: Enum.map(list, &walk(&1, env))
  defp walk(node, _env), do: node

  # The bare-call stamping shared by the generic bare-call clause and the `defmodule`
  # clause: the resolved import (or Kernel displacement), then — when the call resolves to a
  # known macro — its argument routing. The macro stamp runs *after* `Imports.stamp` so it can read the just-applied
  # import / Kernel-displacement marks. Returns `{meta, module_key}` so the caller can also
  # stamp any argument marks the resolved module/function carries (`descend_marked/5`).
  #
  # This one routes the call with its arguments **as written**, for the heads whose clause walks
  # them its own way (`defmodule`, `defimpl`, `quote`, `Kernel.|>/2`). Genuine structural forms
  # take `:skip` alone; displaced definers instead follow their ordinary argument routes.
  defp stamp_bare_call(fun, meta, args, env) do
    {meta, module_key} = resolve_bare_call(fun, meta, args, env)
    {stamp_routed(meta, module_key, fun, args, env), module_key}
  end

  # Classify the written arguments before interpreting their contents as Elixir. The outer
  # call is resolved (including its effective piped arity); the route owns the boundary.
  defp walk_bare_call(fun, meta, module_key, args, env) do
    meta = stamp_routed(meta, module_key, fun, args, env)
    {fun, meta, descend_marked(args, module_key, fun, meta, env)}
  end

  defp resolve_bare_call(fun, meta, args, env) do
    meta = Imports.stamp(fun, meta, args, env.imports, env.kernel)
    {meta, bare_module_key(fun, length(args), meta, env)}
  end

  # A macro can inject a custom operator without exposing its imports to this walk. A winning
  # name-only route explicitly names that operator, so trust it over the default Kernel
  # assumption: keep the call at its written arity and route its two operands. Its provider
  # remains unknown. Use the ordinary displacement stamp so later readers agree, and the
  # registry's ordinary lookup so a more specific Kernel route still wins.
  defp resolve_pipe_call(meta, args, env) do
    {meta, module_key} = resolve_bare_call(:|>, meta, args, env)

    case {module_key, Routes.lookup(env.call_routes, module_key, :|>, 2)} do
      {[:Kernel], %Entry{spec: %Spec{module: :*, name: :|>}}} ->
        {Keyword.put(meta, MetaKeys.kernel_displaced_key(), true), nil}

      _ ->
        {meta, module_key}
    end
  end

  defp stamp_routed(meta, module_key, fun, args, env) do
    meta = RouteStamp.stamp(meta, module_key, fun, args, {fun, meta, args}, env)
    meta |> stamp_mark_call(module_key, fun, args, env) |> retain_environment(env)
  end

  defp retain_environment(meta, env) do
    if Meta.routing(meta) == :skip or is_list(Meta.routing(meta)),
      do: Keyword.put(meta, MetaKeys.resolution_key(), env),
      else: meta
  end

  defp descend(args, env), do: Enum.map(args, &walk(&1, env))

  # The head of a `defmodule`: an `__aliases__` head is *stamped* with its resolved module (for
  # `Mutare.Lifting`; no descent — it's a module path), a non-`__aliases__` (dynamic) head is a live
  # expression, so it is walked so its interior calls resolve.
  defp defmodule_head({:__aliases__, _, _} = head, env),
    do: Aliases.stamp_module(head, env.aliases)

  defp defmodule_head(head, env), do: walk(head, env)

  # The env a genuine `Kernel.defmodule` body is walked under: the enclosing env plus the module it
  # enters (`child_module/3` — the unresolved sentinel for a non-static head) and the in-body
  # self-alias the head introduces.
  defp module_body_env(head, env) do
    child = ModuleScope.child_module(head, env.module, env.aliases)

    aliases =
      ModuleScope.register_defined_module({:defmodule, [], [head]}, env.module, env.aliases)

    %{env | module: child, aliases: aliases}
  end

  # The `for:` type of a `defimpl`, wherever it sits — a standalone opts arg (`defimpl P, for: T do
  # … end`) or the inline combined keyword list (`defimpl P, for: T, do: …`) — or `nil` when inferred
  # (`defimpl P do … end`), which leaves the impl module unresolved.
  defp defimpl_for_type(args) do
    args
    |> Enum.drop(1)
    |> Enum.find_value(fn arg -> if is_list(arg), do: ModuleScope.for_type(arg) end)
  end

  # `descend/2`, preceded by stamping any argument marks the resolved `{module_key, fun}` carries
  # (`Mutare.Transform.Resolve.ArgumentMarks`), then the marked nodes follow their treatments.
  # The stamp rides through untouched. A `|>` stage reaches here as its direct
  # call, so its piped operand is marked as the argument 0 it is.
  defp descend_marked(args, module_key, fun, meta, env) do
    args
    |> ArgumentMarks.stamp(module_key, fun, env.marks)
    |> Arguments.walk(Meta.routing(meta), &walk(&1, env))
  end

  # Record on the call's own meta that a mark declaration matched it (`:mutare_mark_call`) — the
  # side channel `Mutare.Transform.ConfigMatches` reads to find configured `argument_marks:` entries
  # that reached no call. Keyed exactly as `ArgumentMarks.stamp/5` looks the declaration up.
  defp stamp_mark_call(meta, module_key, fun, args, env) do
    arity = length(args)
    ArgumentMarks.stamp_call(meta, module_key, fun, arity, env.marks)
  end

  # A `Kernel.|>/2` as the direct call `Macro.pipe/3` makes of it, walked as any written call
  # is, or `nil` for a right side `Kernel.|>/2` cannot pipe into.
  #
  # Routes choose where this pass walks. Raw/hosted arguments and skipped calls remain
  # written syntax; ordinary Elixir carries the inverse spelling in WrittenPipe's stamp.
  # A skipped Kernel `|>` is withheld before reaching this helper, including its stage.
  defp direct_stage(pipe_meta, lhs, {head, _meta, _written_args} = rhs, env)
       when head not in [:unquote, :unquote_splicing] do
    case direct_call(lhs, rhs) do
      nil ->
        nil

      direct ->
        WrittenPipe.direct(pipe_meta, walk(direct, env))
    end
  end

  defp direct_stage(_pipe_meta, _lhs, _rhs, _env), do: nil

  # `Kernel.|>/2`'s own desugaring. It refuses what cannot be piped into (a literal, a `fn`, a
  # capture, a unary operator) — source that compiles only as a macro's argument, if at all,
  # left exactly as written. Sourceror wraps a literal in a one-child `__block__`, which
  # `Macro.pipe/3` would take for a call and pipe into, making a block of `x |> 1`.
  defp direct_call(_lhs, {:__block__, _meta, [_literal]}), do: nil

  defp direct_call(lhs, rhs) do
    Macro.pipe(lhs, rhs, 0)
  rescue
    ArgumentError -> nil
  end

  defp capture_arity(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp capture_arity({:__block__, _meta, [n]}) when is_integer(n) and n >= 0, do: {:ok, n}
  defp capture_arity(_node), do: :error

  defp placeholder_args(0), do: []
  defp placeholder_args(arity), do: List.duplicate({:_, [], nil}, arity)

  # ImportWitness.for_candidate/1 reads from the candidate's original node. Capture candidates
  # are attached to the outer `&` node, not the inner ref, so copy just the witness payload there
  # while keeping the resolution stamp on the ref where `Calls.resolved_call/1` expects it.
  defp copy_import_witness(amp_meta, ref_meta) do
    case Imports.import_witness(ref_meta) do
      nil -> amp_meta
      witness -> Keyword.put(amp_meta, MetaKeys.import_witness_key(), witness)
    end
  end

  # Extend the env from one statement: the alias env (any statement — an explicit `alias`, or the
  # implicit alias a *genuine* nested `defmodule`/`defprotocol` introduces for its following
  # siblings) and then the import env / Kernel selector (no-op unless an `import`). Imports resolve
  # their module through the *just-updated* alias env (an `import` is never an `alias`, so it is the
  # env in force).
  defp register(stmt, env) do
    aliases =
      stmt
      |> Aliases.register(env.aliases)
      |> maybe_register_defined_module(stmt, env)

    {imports, kernel} = Imports.register(stmt, aliases, env.imports, env.kernel)
    env = %{env | aliases: aliases, imports: imports, kernel: kernel}
    fold_use_directives(stmt, env)
  end

  # Fold the implicit alias a nested module definition introduces for its following siblings — but
  # only for a **genuine** `Kernel.defmodule`/`defprotocol`. A displaced definer (a DSL macro over
  # Kernel's) defines no module named after its head, so installing `Head => Parent.Head` would
  # resolve later siblings to a module that needn't exist. Every other statement passes through.
  defp maybe_register_defined_module(aliases, {form, meta, args} = stmt, env)
       when form in [:defmodule, :defprotocol] and is_list(args) do
    stamped = Imports.stamp(form, meta, args, env.imports, env.kernel)

    if kernel_module_definer?(form, stamped, args, env),
      do: ModuleScope.register_defined_module(stmt, env.module, aliases),
      else: aliases
  end

  defp maybe_register_defined_module(aliases, _stmt, _env), do: aliases

  # A `use` node stamped by `Mutare.Transform.Uses` carries the `import`/`alias` directives it
  # injects. Fold each through `register/2` in source order (so an injected alias-then-import
  # interleave resolves correctly), as if written inline at the `use` — the directives are
  # normalized to Sourceror form, so the ordinary `Aliases`/`Imports` clauses (and the live
  # reflection that resolves a DSL macro) handle them unchanged. A non-`use` statement, or a
  # `use` with no harvested directives, passes through untouched.
  defp fold_use_directives({:use, meta, _args}, env) when is_list(meta),
    do: Enum.reduce(Uses.directives(meta), env, &register/2)

  defp fold_use_directives(_stmt, env), do: env

  # The module key a *bare* call resolves to, for known-macro matching: the imported module
  # if stamped, else `[:Kernel]` only when the name is a genuine `Kernel` export *and* not
  # displaced (`import Kernel, except:`). A local function — or a displaced name — resolves to
  # `nil` (no match), so a bare call is recognised as `Kernel.match?` exactly when it compiles
  # to it (a local `def match?/2` shadowing the Kernel macro is itself a compile error). A
  # **special form** (`case`, `with`, `fn`, `=`, …) resolves to `Kernel.SpecialForms` by *name*:
  # the compiler recognises them by name, and their nominal arities don't track the AST (a `with`
  # node has one argument per clause plus the block). That lets a route `:skip` one
  # (`{Kernel.SpecialForms, :case, :skip}`); positional routes never apply to them
  # (`Mutare.Transform.StructuralForms`). When none of those resolve, fall back to the
  # **registries** for a call reached through a whole
  # import the Mutare process can't reflect on: a registered macro (`registered_macro_module/3`)
  # first, then a declared argument mark (`marked_import_module/3`).
  defp bare_module_key(fun, arity, meta, env) do
    case Imports.resolved_import(meta) do
      {module_key, _kind} ->
        module_key

      nil ->
        cond do
          not Imports.kernel_displaced?(meta) and kernel_export?(fun, arity) ->
            [:Kernel]

          StructuralForms.special_form?(fun) ->
            StructuralForms.special_forms_key()

          true ->
            registered_macro_module(fun, arity, env) || marked_import_module(fun, arity, env)
        end
    end
  end

  # `Imports.stamp` resolves a whole `import Mod` by **reflection** (`Code.ensure_loaded?` +
  # `function_exported?`), so a DSL module defined **only in the target project** — which the
  # Mutare process can't load — leaves a bare macro call's `meta[:mutare_import]` unstamped, and
  # `bare_module_key/4` then returns `nil`. But the user's `:call_routes` entry *asserts* the module
  # provides that macro, and the compile-unambiguity rule means a bare call under a whole import
  # of that module is unambiguously its macro. So when reflection can't resolve the call, consult
  # the registry directly: among the **whole**-imported modules in scope, find one that registers
  # `fun/arity` as a known macro. This is the positive fix for a registered `:raw`/`:pattern` DSL
  # macro whose module Mutare can't see — without it the unstamped block is classified *unknown*
  # and mutated as an ordinary runtime body, which can poison the very DSL the registration meant
  # to exclude (and `Runner.escalate_block_poison/3` can then drop every sibling mutant in the block).
  # Limited to whole imports: a selective `import Mod, only: [m: 1]` already resolves without
  # reflection (the `{:only, set}` is read straight from the source), so it never reaches here.
  #
  # `env.imports` is a **map**, so its iteration order is undefined; sort the candidates before
  # picking, so the chosen module is **deterministic** across runs (the stamped identity feeds
  # `meta[:mutare_route_call]`, and a `:hosted`/`:routing` mutator may key on it — a run-to-run
  # flip would be a non-reproducible result, and the **mutant-id stability** Mutare relies on for
  # poison recovery assumes a stable analysis). More than one match is itself degenerate: a bare
  # call under two whole imports that *both* genuinely export `fun/arity` is an ambiguous call that
  # would not compile, so a compiling program has at most one real provider — a second match means
  # the (syntactic, un-reflected) registry over-claims a module that doesn't truly export it. Either
  # way the treatment is the same, so any deterministic pick is sound; sorting by module key is the
  # stable, explanation-free choice.
  defp registered_macro_module(fun, arity, env) do
    env.imports
    |> Enum.sort()
    |> Enum.find_value(fn {module_key, selector} ->
      if Imports.whole?(selector) and Routes.lookup(env.call_routes, module_key, fun, arity),
        do: module_key
    end)
  end

  # The marks-registry twin of `registered_macro_module/3`: a bare call under a whole import of a
  # module the Mutare process can't reflect on, whose `{module, fun, arity}` some mutator *declared*
  # an argument mark for (`argument_marks/1`, or an `argument_marks:` config entry naming a target-project
  # module). The declaration asserts the module provides `fun/arity`, and the compile-unambiguity
  # rule does the rest, so `descend_marked/5` can
  # stamp the configured positions on the imported bare form just as on the remote/selective-import
  # forms. Wrong-declaration risk runs only in the safe direction — a mark can at most *suppress* a
  # mutant, never mis-resolve a mutation. Same determinism argument as above (sorted fold); limited
  # to whole imports for the same reason (a selective import already resolves without reflection).
  defp marked_import_module(fun, arity, env) do
    env.imports
    |> Enum.sort()
    |> Enum.find_value(fn {module_key, selector} ->
      if Imports.whole?(selector) and ArgumentMarks.declares?(env.marks, module_key, fun, arity),
        do: module_key
    end)
  end

  defp kernel_export?(fun, arity),
    do: function_exported?(Kernel, fun, arity) or macro_exported?(Kernel, fun, arity)

  # Whether a `defmodule`/`defprotocol` call is the genuine `Kernel` macro — the only form that
  # defines a module Elixir auto-aliases and scopes. `meta` must already carry the `Imports` stamp
  # (`bare_module_key/4` reads it). A displaced definer (`import Kernel, except: [defmodule: 2]` +
  # a DSL's own `defmodule`) resolves to that DSL module (or `nil`), never `[:Kernel]`, so its head
  # neither opens a module scope nor installs an implicit alias.
  defp kernel_module_definer?(form, meta, args, env),
    do: bare_module_key(form, length(args), meta, env) == [:Kernel]

  # === quote data ============================================================

  # `QuoteStructure` says which parts run; this pass resolves those and leaves data as written.
  defp walk_live_quote_args(args, env) do
    {parts, rebuild} = QuoteStructure.parts(args)

    parts
    |> Enum.map(fn
      {value, :live} -> walk(value, env)
      {value, :quoted} -> walk_quoted_data(value, env)
      {value, :inert} -> value
    end)
    |> rebuild.()
  end

  # A live unquote is a resolvable head too (`Kernel.SpecialForms.unquote`): stamp it, so a `:skip`
  # route on it is honoured by `Analyze.QuoteEscape` and the escaping argument stays as written.
  defp walk_quoted_data({form, meta, args} = node, env) when is_list(args) do
    case QuoteStructure.quoted(node) do
      {:escape, arg, _rebuild} ->
        {meta, _module_key} = stamp_bare_call(form, meta, [arg], env)
        {form, meta, if(Meta.routing(meta) == :skip, do: [arg], else: [walk(arg, env)])}

      {:options, options, rebuild} ->
        rebuild.(walk_quoted_data(options, env))

      :inert ->
        node

      :data ->
        {walk_quoted_data(form, env), meta, Enum.map(args, &walk_quoted_data(&1, env))}
    end
  end

  defp walk_quoted_data({left, right}, env),
    do: {walk_quoted_data(left, env), walk_quoted_data(right, env)}

  defp walk_quoted_data(list, env) when is_list(list),
    do: Enum.map(list, &walk_quoted_data(&1, env))

  defp walk_quoted_data(other, _env), do: other
end
