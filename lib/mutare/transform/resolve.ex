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
  # (the tracked `Kernel` selector, default `:all`), and `piped?` (whether the current node is
  # a `|>` right-hand side — so `Imports` can recover a piped call's effective arity).

  alias Mutare.{Macros, Mutator}
  alias Mutare.Transform.{Aliases, Imports}

  @macro_key :mutare_macro

  @doc "Stamp every remote call's module and every bare imported call with its resolved module."
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast), do: annotate(ast, %{})

  @doc """
  As `annotate/1`, plus stamp each call that resolves to a **known macro** (in the
  `registry` built by `Mutare.Macros.build/2`) with its per-argument routing under
  `meta[:mutare_macro]`, so the analyzer routes a pattern/opaque argument correctly
  instead of mutating it. The registry is carried in the env (read-only) and
  consulted at each remote and bare call.
  """
  @spec annotate(Macro.t(), Macros.registry()) :: Macro.t()
  def annotate(ast, registry),
    do:
      walk(ast, %{
        aliases: %{},
        imports: %{},
        kernel: Imports.default_selector(),
        piped: false,
        macros: registry
      })

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

  # `|>` pipe: the RHS is a call whose effective first argument is the LHS, so it carries one
  # fewer written arg — resolve it as *piped* (effective arity +1), the LHS normally. The
  # RHS's own arguments are ordinary expressions, so descent resets the flag.
  defp walk({:|>, meta, [lhs, rhs]}, env) do
    {:|>, meta, [walk(lhs, %{env | piped: false}), walk(rhs, %{env | piped: true})]}
  end

  # A remote call `Mod.fun(...)`: stamp its module position with the alias-resolved module
  # (and, when it resolves to a known macro, its argument routing on the call meta), then
  # descend the arguments un-piped (they may contain bare imported calls).
  defp walk({{:., dot_meta, [{:__aliases__, _am, path} = aliases, fun]}, call_meta, args}, env)
       when is_list(args) do
    stamped = Aliases.stamp_module(aliases, env.aliases)
    call_meta = stamp_macro(call_meta, Aliases.resolve_path(path, env.aliases), fun, args, env)
    {{:., dot_meta, [stamped, fun]}, call_meta, descend(args, env)}
  end

  # A bare call `fun(...)`: stamp it with its resolved import (or Kernel-displacement) using
  # the current pipe context for effective arity, then — when it resolves to a known macro —
  # its argument routing, then descend the arguments un-piped. The macro stamp runs *after*
  # `Imports.stamp` so it can read the just-applied import / Kernel-displacement marks.
  defp walk({fun, meta, args}, env) when is_atom(fun) and is_list(args) do
    meta = Imports.stamp(fun, meta, args, env.imports, env.kernel, env.piped)
    arity = Mutator.effective_arity(args, env.piped)
    meta = stamp_macro(meta, bare_module_key(fun, arity, meta), fun, args, env)
    {fun, meta, descend(args, env)}
  end

  # Any other n-ary node (`__aliases__`, operators with a tuple form, …): nothing to stamp —
  # descend the arguments un-piped.
  defp walk({form, meta, args}, env) when is_list(args), do: {form, meta, descend(args, env)}

  defp walk({left, right}, env), do: {walk(left, env), walk(right, env)}
  defp walk(list, env) when is_list(list), do: Enum.map(list, &walk(&1, env))
  defp walk(node, _env), do: node

  defp descend(args, env), do: Enum.map(args, &walk(&1, %{env | piped: false}))

  # Extend the env from one statement: the alias env (any statement, no-op unless an `alias`)
  # and then the import env / Kernel selector (no-op unless an `import`). Imports resolve their
  # module through the *just-updated* alias env (an `import` is never an `alias`, so it is the
  # env in force).
  defp register(stmt, env) do
    aliases = Aliases.register(stmt, env.aliases)
    {imports, kernel} = Imports.register(stmt, aliases, env.imports, env.kernel)
    %{env | aliases: aliases, imports: imports, kernel: kernel}
  end

  # Stamp a call's meta with the argument routing of the known macro it resolves to, or leave
  # it unchanged. Pipe-aware: a stage `lhs |> macro(a, b)` is `macro(lhs, a, b)`, so the match
  # uses the *effective* arity (visible + 1) and the looked-up routing is for the effective
  # positions. The piped value (effective position 0 — the `|>` LHS, analyzed by the `:|>`
  # clause, not part of this node's args) is dropped, so the stamp carries only the routing for
  # the **visible** args — which is what the analyzer routes. This is what protects a piped DSL
  # stage (`q |> where([p], p.x == 1)`): without it core would descend into the condition.
  defp stamp_macro(meta, module_key, fun, args, env) do
    arity = Mutator.effective_arity(args, env.piped)

    case Macros.routing(env.macros, module_key, fun, arity) do
      nil -> meta
      routing -> [{@macro_key, visible_routing(routing, env.piped)} | meta]
    end
  end

  # Drop the piped value's treatment (effective position 0) so the stamp lines up with the
  # node's visible args; un-piped, every position is visible. A piped call always has effective
  # arity >= 1, so the routing list is non-empty and `tl/1` is safe.
  defp visible_routing(routing, true), do: tl(routing)
  defp visible_routing(routing, false), do: routing

  # The module key a *bare* call resolves to, for known-macro matching: the imported module
  # if stamped, else `[:Kernel]` only when the name is a genuine `Kernel` export *and* not
  # displaced (`import Kernel, except:`). A local function — or a displaced name — resolves to
  # `nil` (no match), so a bare call is recognised as `Kernel.match?` exactly when it compiles
  # to it (a local `def match?/2` shadowing the Kernel macro is itself a compile error).
  defp bare_module_key(fun, arity, meta) do
    case Imports.resolved_import(meta) do
      {module_key, _kind} ->
        module_key

      nil ->
        if not Imports.kernel_displaced?(meta) and kernel_export?(fun, arity),
          do: [:Kernel],
          else: nil
    end
  end

  defp kernel_export?(fun, arity),
    do: function_exported?(Kernel, fun, arity) or macro_exported?(Kernel, fun, arity)
end
