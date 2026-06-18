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

  alias Mutare.Transform.{Aliases, Imports}

  @doc "Stamp every remote call's module and every bare imported call with its resolved module."
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast),
    do: walk(ast, %{aliases: %{}, imports: %{}, kernel: Imports.default_selector(), piped: false})

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

  # A remote call `Mod.fun(...)`: stamp its module position with the alias-resolved module,
  # then descend the arguments un-piped (they may contain bare imported calls).
  defp walk({{:., dot_meta, [{:__aliases__, _am, _path} = aliases, fun]}, call_meta, args}, env)
       when is_list(args) do
    aliases = Aliases.stamp_module(aliases, env.aliases)
    {{:., dot_meta, [aliases, fun]}, call_meta, descend(args, env)}
  end

  # A bare call `fun(...)`: stamp it with its resolved import (or Kernel-displacement) using
  # the current pipe context for effective arity, then descend the arguments un-piped.
  defp walk({fun, meta, args}, env) when is_atom(fun) and is_list(args) do
    meta = Imports.stamp(fun, meta, args, env.imports, env.kernel, env.piped)
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
end
