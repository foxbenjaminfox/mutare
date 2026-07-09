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
  # (the tracked `Kernel` selector, default `:all`), `pipe_mode` (`:piped`/`:unpiped` — whether the
  # current node is a `|>` right-hand side, so `Imports` can recover a piped call's effective
  # arity), and `module` (the enclosing module, `nil` at the top level — the one piece of module
  # scope this pass tracks, so `Mutare.Transform.ModuleScope` can fold the implicit alias a nested
  # `defmodule` introduces; a call to a sibling nested module by short name then resolves to the
  # module Elixir defines, matching a `:macro_routes` entry keyed on it). Bare function captures
  # (`&fun/N`) are not calls syntactically, but when
  # `fun/N` resolves to an import they get the same import stamp a synthesized `fun(args…)` probe
  # needs for capture mutation.

  alias Mutare.AST
  alias Mutare.MacroRouting.Registry, as: Macros
  alias Mutare.Mutator
  alias Mutare.Transform.{Aliases, Calls, Imports, MetaKeys, ModuleScope, Uses}
  alias Mutare.Transform.Resolve.{ArgumentMarks, MacroStamp, NodeIds}

  @doc "Stamp remote calls, bare imported calls, and bare imported captures with their resolved module."
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast), do: annotate(ast, %Macros{routes: %{}, hosts: []})

  @doc """
  As `annotate/1`, plus stamp each call that resolves to a **known macro** (in the
  `registry` built by `Mutare.MacroRouting.Registry.build/3`) with its per-argument routing under
  `meta[:mutare_macro]`, so the analyzer routes a pattern/opaque argument correctly
  instead of mutating it. The registry is carried in the env (read-only) and
  consulted at each remote and bare call.

  `opts` carries the pass's diagnostics wiring: `:warnings` (default `true`) gates the
  advisory classifier warnings `MacroStamp` may print, and `:file` labels them. The
  transform's two-phase callers disable warnings on re-runs of the same source so each
  prints once (see `Mutare.Transform`'s `:warnings` option).
  """
  @spec annotate(Macro.t(), Macros.registry(), keyword()) :: Macro.t()
  def annotate(ast, registry, opts \\ []) do
    ast
    |> walk(%{
      aliases: %{},
      imports: %{},
      kernel: Imports.default_selector(),
      pipe_mode: :unpiped,
      # The enclosing module (`nil` at the file top level), threaded so `ModuleScope` can fold the
      # implicit alias Elixir introduces for a nested module — a sibling nested module referred to
      # by short name then resolves to what the compiler defines (`Outer.Foo`, not the bare `Foo`).
      module: nil,
      macro_routes: registry,
      marks: Keyword.get(opts, :marks, ArgumentMarks.empty()),
      diag: %{
        warn?: Keyword.get(opts, :warnings, true),
        file: Keyword.get(opts, :file, "nofile")
      }
    })
    |> NodeIds.stamp()
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
  defp walk({:quote, meta, args} = node, env) when is_list(args) do
    walked = walk_live_quote_args(args, env)

    if walked == args, do: node, else: {:quote, meta, walked}
  end

  # `|>` pipe: the RHS is a call whose effective first argument is the LHS, so it carries one
  # fewer written arg — resolve it as *piped* (effective arity +1), the LHS normally. The
  # RHS's own arguments are ordinary expressions, so descent resets the flag. The LHS *is* the
  # RHS's effective argument 0, so if the RHS marks that position (`Process.sleep/1`,
  # `:timer.sleep/1`, or a custom index-0 mark) `mark_pipe_receiver/3` marks the LHS — the piped
  # counterpart of the visible-arg stamping the RHS clause did.
  defp walk({:|>, meta, [lhs, rhs]}, env) do
    rhs = walk(rhs, %{env | pipe_mode: :piped})
    lhs = mark_pipe_receiver(walk(lhs, %{env | pipe_mode: :unpiped}), rhs, env)
    {:|>, meta, [lhs, rhs]}
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
    case capture_arity(right) do
      {:ok, arity} ->
        ref_meta =
          Imports.stamp(fun, ref_meta, placeholder_args(arity), env.imports, env.kernel, :unpiped)

        amp_meta = copy_import_witness(amp_meta, ref_meta)
        {:&, amp_meta, [{:/, slash_meta, [{fun, ref_meta, context}, right]}]}

      :error ->
        {:&, amp_meta, [walk({:/, slash_meta, [ref, right]}, env)]}
    end
  end

  # A remote call `Mod.fun(...)`: stamp its module position with the alias-resolved module
  # (and, when it resolves to a known macro, its argument routing on the call meta), then
  # descend the arguments un-piped (they may contain bare imported calls).
  defp walk({{:., dot_meta, [{:__aliases__, _am, path} = aliases, fun]}, call_meta, args}, env)
       when is_list(args) do
    stamped = Aliases.stamp_module(aliases, env.aliases)
    module_key = Aliases.resolve_path(path, env.aliases)
    call_node = {{:., dot_meta, [aliases, fun]}, call_meta, args}

    call_meta =
      MacroStamp.stamp(
        call_meta,
        module_key,
        fun,
        args,
        call_node,
        env.macro_routes,
        env.pipe_mode,
        env.diag
      )

    {{:., dot_meta, [stamped, fun]}, call_meta, descend_marked(args, module_key, fun, env)}
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
  # (`obj.fun(...)`), and so on — so it is **walked** (un-piped, in the same lexical scope), letting
  # an aliased/imported/known-macro call sitting in the receiver get its stamp instead of being
  # silently skipped (the old generic-clause behaviour). The function-name atom `fun` is never
  # touched. (Analyze mirrors this split — `descend_receiver/2` — so such a receiver is also offered
  # to mutators.)
  defp walk({{:., dot_meta, [mod, fun]}, call_meta, args}, env)
       when is_atom(fun) and is_list(args) do
    case Aliases.resolve_node(mod, %{}) do
      nil ->
        walked = walk(mod, %{env | pipe_mode: :unpiped})
        {{:., dot_meta, [walked, fun]}, call_meta, descend(args, env)}

      module_key ->
        call_node = {{:., dot_meta, [mod, fun]}, call_meta, args}

        call_meta =
          MacroStamp.stamp(
            call_meta,
            module_key,
            fun,
            args,
            call_node,
            env.macro_routes,
            env.pipe_mode,
            env.diag
          )

        {{:., dot_meta, [mod, fun]}, call_meta, descend_marked(args, module_key, fun, env)}
    end
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
    {meta, _module_key} = stamp_bare_call(:defmodule, meta, args, env)

    body_env =
      if kernel_module_definer?(:defmodule, meta, args, env),
        do: module_body_env(head, env),
        else: %{env | pipe_mode: :unpiped}

    {:defmodule, meta, [defmodule_head(head, env), walk(body, body_env)]}
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
  defp walk({:defimpl, meta, args}, env) when is_list(args) and length(args) >= 2 do
    {meta, _module_key} = stamp_bare_call(:defimpl, meta, args, env)
    enclosing = %{env | pipe_mode: :unpiped}

    if kernel_module_definer?(:defimpl, meta, args, env) do
      impl = ModuleScope.impl_module(hd(args), defimpl_for_type(args), env.aliases)
      {lead, [last]} = Enum.split(args, -1)
      walked = Enum.map(lead, &walk(&1, enclosing)) ++ [walk(last, %{enclosing | module: impl})]
      {:defimpl, meta, walked}
    else
      {:defimpl, meta, descend(args, env)}
    end
  end

  # A bare call `fun(...)`: stamp it with its resolved import (or Kernel-displacement) using
  # the current pipe context for effective arity, then — when it resolves to a known macro —
  # its argument routing, then descend the arguments un-piped.
  defp walk({fun, meta, args}, env) when is_atom(fun) and is_list(args) do
    {meta, module_key} = stamp_bare_call(fun, meta, args, env)
    {fun, meta, descend_marked(args, module_key, fun, env)}
  end

  # Any other n-ary node (`__aliases__`, operators with a tuple form, …): nothing to stamp —
  # descend the arguments un-piped.
  defp walk({form, meta, args}, env) when is_list(args), do: {form, meta, descend(args, env)}

  defp walk({left, right}, env), do: {walk(left, env), walk(right, env)}
  defp walk(list, env) when is_list(list), do: Enum.map(list, &walk(&1, env))
  defp walk(node, _env), do: node

  # The bare-call stamping shared by the generic bare-call clause and the `defmodule`
  # clause: the resolved import (or Kernel displacement) using the current pipe context
  # for effective arity, then — when the call resolves to a known macro — its argument
  # routing. The macro stamp runs *after* `Imports.stamp` so it can read the just-applied
  # import / Kernel-displacement marks. Returns `{meta, module_key}` so the caller can also
  # stamp any argument marks the resolved module/function carries (`descend_marked/4`).
  defp stamp_bare_call(fun, meta, args, env) do
    meta = Imports.stamp(fun, meta, args, env.imports, env.kernel, env.pipe_mode)
    arity = Mutator.effective_arity(args, env.pipe_mode)
    module_key = bare_module_key(fun, arity, meta, env)

    meta =
      MacroStamp.stamp(
        meta,
        module_key,
        fun,
        args,
        {fun, meta, args},
        env.macro_routes,
        env.pipe_mode,
        env.diag
      )

    {meta, module_key}
  end

  defp descend(args, env), do: Enum.map(args, &walk(&1, %{env | pipe_mode: :unpiped}))

  # The head of a `defmodule`: an `__aliases__` head is *stamped* with its resolved module (for
  # `Mutare.Lifting`; no descent — it's a module path), a non-`__aliases__` (dynamic) head is a live
  # expression, so it is walked so its interior calls resolve.
  defp defmodule_head({:__aliases__, _, _} = head, env),
    do: Aliases.stamp_module(head, env.aliases)

  defp defmodule_head(head, env), do: walk(head, %{env | pipe_mode: :unpiped})

  # The env a genuine `Kernel.defmodule` body is walked under: the enclosing env plus the module it
  # enters (`child_module/3` — the unresolved sentinel for a non-static head) and the in-body
  # self-alias the head introduces.
  defp module_body_env(head, env) do
    child = ModuleScope.child_module(head, env.module, env.aliases)

    aliases =
      ModuleScope.register_defined_module({:defmodule, [], [head]}, env.module, env.aliases)

    %{env | pipe_mode: :unpiped, module: child, aliases: aliases}
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
  # (`Mutare.Transform.Resolve.ArgumentMarks`). The marks are computed against the call's own pipe
  # context (a piped receiver is effective arg 0), then the marked nodes are descended un-piped like
  # every other argument — the stamp rides through untouched.
  defp descend_marked(args, module_key, fun, env),
    do: args |> ArgumentMarks.stamp(module_key, fun, env.pipe_mode, env.marks) |> descend(env)

  # Mark a pipe's left side — the RHS call's effective argument 0, which `descend_marked/4` can't
  # reach because it isn't in the RHS's visible args — when the RHS marks index 0. The cheap
  # `receiver_fun?` pre-filter runs first; only then is the RHS target resolved.
  defp mark_pipe_receiver(lhs, rhs, env) do
    if ArgumentMarks.receiver_fun?(rhs, env.marks) do
      case pipe_target(rhs, env) do
        {module_key, fun, effective_arity} ->
          case ArgumentMarks.receiver_labels(module_key, fun, effective_arity, env.marks) do
            nil -> lhs
            labels -> ArgumentMarks.mark_argument(lhs, labels)
          end

        nil ->
          lhs
      end
    else
      lhs
    end
  end

  # The resolved `{module_key, function, effective_arity}` of a walked pipe RHS call, or `nil`. A
  # remote/erlang head resolves via `Calls.resolved_call/1` (reading the stamps this pass just
  # placed); a bare head via `bare_module_key/4` (the import/Kernel resolution the bare-call clause
  # used) — so a bare `Kernel` or imported RHS resolves the same as when the call is written
  # non-piped, honouring the effective-index-0 contract there too.
  defp pipe_target({{:., _dm, [_recv, fun]}, _meta, args} = rhs, _env)
       when is_atom(fun) and is_list(args) do
    case Calls.resolved_call(rhs) do
      {module_key, ^fun, _args, _rebuild} -> {module_key, fun, length(args) + 1}
      _ -> nil
    end
  end

  defp pipe_target({fun, meta, args}, env) when is_atom(fun) and is_list(args),
    do:
      {bare_module_key(fun, Mutator.effective_arity(args, :piped), meta, env), fun,
       length(args) + 1}

  # A bare RHS written parenless (`123 |> to_string`, `1000 |> sleep`) is `{fun, meta, nil}`, which
  # the generic `walk/2` leaves unstamped (a bare `{fun, meta, nil}` is a variable outside pipe
  # position, so it can't be blanket-resolved as a call). As a pipe RHS it *is* a 0-visible-arg call
  # whose effective argument 0 is the LHS, so resolve its import here — mirroring `stamp_bare_call/4`
  # — before keying, so an imported/`Kernel` receiver mark applies to the parenless form too.
  defp pipe_target({fun, meta, nil}, env) when is_atom(fun) do
    meta = Imports.stamp(fun, meta, [], env.imports, env.kernel, :piped)
    {bare_module_key(fun, 1, meta, env), fun, 1}
  end

  defp pipe_target(_rhs, _env), do: nil

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
    stamped = Imports.stamp(form, meta, args, env.imports, env.kernel, :unpiped)

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
  # to it (a local `def match?/2` shadowing the Kernel macro is itself a compile error). When
  # none of those resolve, fall back to the **registries** for a call reached through a whole
  # import the Mutare process can't reflect on: a registered macro (`registered_macro_module/3`)
  # first, then a declared argument mark (`marked_import_module/3`).
  defp bare_module_key(fun, arity, meta, env) do
    case Imports.resolved_import(meta) do
      {module_key, _kind} ->
        module_key

      nil ->
        if not Imports.kernel_displaced?(meta) and kernel_export?(fun, arity),
          do: [:Kernel],
          else: registered_macro_module(fun, arity, env) || marked_import_module(fun, arity, env)
    end
  end

  # `Imports.stamp` resolves a whole `import Mod` by **reflection** (`Code.ensure_loaded?` +
  # `function_exported?`), so a DSL module defined **only in the target project** — which the
  # Mutare process can't load — leaves a bare macro call's `meta[:mutare_import]` unstamped, and
  # `bare_module_key/4` then returns `nil`. But the user's `:macro_routes` entry *asserts* the module
  # provides that macro, and the compile-unambiguity rule means a bare call under a whole import
  # of that module is unambiguously its macro. So when reflection can't resolve the call, consult
  # the registry directly: among the **whole**-imported modules in scope, find one that registers
  # `fun/arity` as a known macro. This is the positive fix for a registered `:skip`/`:pattern` DSL
  # macro whose module Mutare can't see — without it the unstamped block is classified *unknown*
  # and mutated as an ordinary runtime body, which can poison the very DSL the registration meant
  # to exclude (and `Runner.escalate_block_poison/3` can then drop every sibling mutant in the block).
  # Limited to whole imports: a selective `import Mod, only: [m: 1]` already resolves without
  # reflection (the `{:only, set}` is read straight from the source), so it never reaches here.
  #
  # `env.imports` is a **map**, so its iteration order is undefined; sort the candidates before
  # picking, so the chosen module is **deterministic** across runs (the stamped identity feeds
  # `meta[:mutare_macro_call]`, and a `:hosted`/`:routing` mutator may key on it — a run-to-run
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
      if Imports.whole?(selector) and Macros.lookup(env.macro_routes, module_key, fun, arity),
        do: module_key
    end)
  end

  # The marks-registry twin of `registered_macro_module/3`: a bare call under a whole import of a
  # module the Mutare process can't reflect on, whose `{module, fun, arity}` some mutator *declared*
  # an argument mark for (`argument_marks/1` — e.g. a `:skip_arguments` entry naming a target-project
  # module). The declaration asserts the module provides `fun/arity`, and the compile-unambiguity
  # rule does the rest, so `descend_marked/4` (and the piped-receiver path, via `pipe_target/2`) can
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
    do: bare_module_key(form, Mutator.effective_arity(args, :unpiped), meta, env) == [:Kernel]

  # === quote data ============================================================

  defp walk_live_quote_args(args, env) do
    body_unquote_enabled? = quote_unquote_enabled?(args)
    Enum.map(args, &walk_live_quote_arg(&1, body_unquote_enabled?, env))
  end

  defp walk_live_quote_arg({:__block__, meta, [kw]}, body_unquote_enabled?, env)
       when is_list(kw) do
    {:__block__, meta, [walk_live_quote_keyword(kw, body_unquote_enabled?, env)]}
  end

  defp walk_live_quote_arg(kw, body_unquote_enabled?, env) when is_list(kw) do
    walk_live_quote_keyword(kw, body_unquote_enabled?, env)
  end

  defp walk_live_quote_arg(other, body_unquote_enabled?, env) do
    if body_unquote_enabled?,
      do: walk_quoted_data(other, 1, env),
      else: other
  end

  defp walk_live_quote_keyword(kw, body_unquote_enabled?, env) do
    Enum.map(kw, fn
      {key, value} = pair ->
        case AST.key_atom(key) do
          :do when body_unquote_enabled? ->
            {key, walk_quoted_data(value, 1, env)}

          :do ->
            pair

          _option ->
            {key, walk(value, %{env | pipe_mode: :unpiped})}
        end

      other ->
        other
    end)
  end

  defp walk_quoted_data({:quote, meta, args} = node, quote_level, env) when is_list(args) do
    walked = walk_quoted_quote_args(args, quote_level, env)

    if walked == args, do: node, else: {:quote, meta, walked}
  end

  defp walk_quoted_data({form, meta, [arg]}, 1, env)
       when form in [:unquote, :unquote_splicing],
       do: {form, meta, [walk(arg, %{env | pipe_mode: :unpiped})]}

  defp walk_quoted_data({form, _meta, [_arg]} = node, quote_level, _env)
       when form in [:unquote, :unquote_splicing] and quote_level > 1,
       do: node

  defp walk_quoted_data({form, meta, args}, quote_level, env) when is_list(args),
    do:
      {walk_quoted_data(form, quote_level, env), meta,
       Enum.map(args, &walk_quoted_data(&1, quote_level, env))}

  defp walk_quoted_data({left, right}, quote_level, env),
    do: {walk_quoted_data(left, quote_level, env), walk_quoted_data(right, quote_level, env)}

  defp walk_quoted_data(list, quote_level, env) when is_list(list),
    do: Enum.map(list, &walk_quoted_data(&1, quote_level, env))

  defp walk_quoted_data(other, _quote_level, _env), do: other

  defp walk_quoted_quote_args(args, quote_level, env) do
    body_unquote_enabled? = quote_unquote_enabled?(args)
    Enum.map(args, &walk_quoted_quote_arg(&1, quote_level, body_unquote_enabled?, env))
  end

  defp walk_quoted_quote_arg({:__block__, meta, [kw]}, quote_level, body_unquote_enabled?, env)
       when is_list(kw) do
    {:__block__, meta, [walk_quoted_quote_keyword(kw, quote_level, body_unquote_enabled?, env)]}
  end

  defp walk_quoted_quote_arg(kw, quote_level, body_unquote_enabled?, env) when is_list(kw) do
    walk_quoted_quote_keyword(kw, quote_level, body_unquote_enabled?, env)
  end

  defp walk_quoted_quote_arg(other, quote_level, body_unquote_enabled?, env) do
    if body_unquote_enabled?,
      do: walk_quoted_data(other, quote_level + 1, env),
      else: other
  end

  defp walk_quoted_quote_keyword(kw, quote_level, body_unquote_enabled?, env) do
    Enum.map(kw, fn
      {key, value} = pair ->
        case AST.key_atom(key) do
          :do when body_unquote_enabled? ->
            {key, walk_quoted_data(value, quote_level + 1, env)}

          :do ->
            pair

          _option ->
            {key, walk_quoted_data(value, quote_level, env)}
        end

      other ->
        other
    end)
  end

  @missing_quote_option :__mutare_missing_quote_option__

  defp quote_unquote_enabled?(args) when is_list(args) do
    pairs = quote_keyword_pairs(args)

    case AST.opts_get(pairs, :unquote, @missing_quote_option) do
      @missing_quote_option ->
        AST.opts_get(pairs, :bind_quoted, @missing_quote_option) == @missing_quote_option

      value ->
        not literal_false?(value)
    end
  end

  defp quote_keyword_pairs(args) do
    Enum.flat_map(args, fn
      {:__block__, _meta, [kw]} when is_list(kw) ->
        Enum.filter(kw, &keyword_pair?/1)

      {_key, _value} = pair ->
        [pair]

      kw when is_list(kw) ->
        Enum.filter(kw, &keyword_pair?/1)

      _other ->
        []
    end)
  end

  defp keyword_pair?({_key, _value}), do: true
  defp keyword_pair?(_other), do: false

  defp literal_false?(false), do: true
  defp literal_false?({:__block__, _meta, [false]}), do: true
  defp literal_false?(_other), do: false
end
