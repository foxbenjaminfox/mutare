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
  # (the tracked `Kernel` selector, default `:all`), and `pipe_mode` (`:piped`/`:unpiped` —
  # whether the current node is a `|>` right-hand side, so `Imports` can recover a piped call's
  # effective arity). Bare function captures (`&fun/N`) are not calls syntactically, but when
  # `fun/N` resolves to an import they get the same import stamp a synthesized `fun(args…)` probe
  # needs for capture mutation.

  alias Mutare.AST
  alias Mutare.MacroRouting.Registry, as: Macros
  alias Mutare.Mutator
  alias Mutare.Transform.{Aliases, Imports, MetaKeys, Uses}
  alias Mutare.Transform.Resolve.{MacroStamp, NodeIds}

  @doc "Stamp remote calls, bare imported calls, and bare imported captures with their resolved module."
  @spec annotate(Macro.t()) :: Macro.t()
  def annotate(ast), do: annotate(ast, %{})

  @doc """
  As `annotate/1`, plus stamp each call that resolves to a **known macro** (in the
  `registry` built by `Mutare.MacroRouting.Registry.build/3`) with its per-argument routing under
  `meta[:mutare_macro]`, so the analyzer routes a pattern/opaque argument correctly
  instead of mutating it. The registry is carried in the env (read-only) and
  consulted at each remote and bare call.
  """
  @spec annotate(Macro.t(), Macros.registry()) :: Macro.t()
  def annotate(ast, registry) do
    ast
    |> walk(%{
      aliases: %{},
      imports: %{},
      kernel: Imports.default_selector(),
      pipe_mode: :unpiped,
      macro_routes: registry
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
  # Walk only escaping `unquote`/`unquote_splicing` arguments, resolving them under the env at the
  # quote site. That keeps a quoted directive such as `alias List, as: S` from restamping
  # `unquote(S.trim(s))`, whose expression is evaluated in the outer scope.
  defp walk({:quote, meta, args} = node, env) when is_list(args) do
    if quote_unquote_enabled?(args),
      do: {:quote, meta, walk_quote_args(args, 1, env)},
      else: node
  end

  # `|>` pipe: the RHS is a call whose effective first argument is the LHS, so it carries one
  # fewer written arg — resolve it as *piped* (effective arity +1), the LHS normally. The
  # RHS's own arguments are ordinary expressions, so descent resets the flag.
  defp walk({:|>, meta, [lhs, rhs]}, env) do
    {:|>, meta, [walk(lhs, %{env | pipe_mode: :unpiped}), walk(rhs, %{env | pipe_mode: :piped})]}
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
        env.pipe_mode
      )

    {{:., dot_meta, [stamped, fun]}, call_meta, descend(args, env)}
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
            env.pipe_mode
          )

        {{:., dot_meta, [mod, fun]}, call_meta, descend(args, env)}
    end
  end

  # A bare call `fun(...)`: stamp it with its resolved import (or Kernel-displacement) using
  # the current pipe context for effective arity, then — when it resolves to a known macro —
  # its argument routing, then descend the arguments un-piped. The macro stamp runs *after*
  # `Imports.stamp` so it can read the just-applied import / Kernel-displacement marks.
  defp walk({fun, meta, args}, env) when is_atom(fun) and is_list(args) do
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
        env.pipe_mode
      )

    {fun, meta, descend(args, env)}
  end

  # Any other n-ary node (`__aliases__`, operators with a tuple form, …): nothing to stamp —
  # descend the arguments un-piped.
  defp walk({form, meta, args}, env) when is_list(args), do: {form, meta, descend(args, env)}

  defp walk({left, right}, env), do: {walk(left, env), walk(right, env)}
  defp walk(list, env) when is_list(list), do: Enum.map(list, &walk(&1, env))
  defp walk(node, _env), do: node

  defp descend(args, env), do: Enum.map(args, &walk(&1, %{env | pipe_mode: :unpiped}))

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

  # Extend the env from one statement: the alias env (any statement, no-op unless an `alias`)
  # and then the import env / Kernel selector (no-op unless an `import`). Imports resolve their
  # module through the *just-updated* alias env (an `import` is never an `alias`, so it is the
  # env in force).
  defp register(stmt, env) do
    aliases = Aliases.register(stmt, env.aliases)
    {imports, kernel} = Imports.register(stmt, aliases, env.imports, env.kernel)
    env = %{env | aliases: aliases, imports: imports, kernel: kernel}
    fold_use_directives(stmt, env)
  end

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
  # none of those resolve, fall back to the **registry** for a registered macro reached through
  # a whole import the Mutare process can't reflect on (`registered_macro_module/3`).
  defp bare_module_key(fun, arity, meta, env) do
    case Imports.resolved_import(meta) do
      {module_key, _kind} ->
        module_key

      nil ->
        if not Imports.kernel_displaced?(meta) and kernel_export?(fun, arity),
          do: [:Kernel],
          else: registered_macro_module(fun, arity, env)
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

  defp kernel_export?(fun, arity),
    do: function_exported?(Kernel, fun, arity) or macro_exported?(Kernel, fun, arity)

  # === quote data ============================================================

  defp walk_quote_args(args, quote_level, env) do
    Enum.map(args, &walk_quote_arg(&1, quote_level, env))
  end

  defp walk_quote_arg({:__block__, meta, [kw]}, quote_level, env) when is_list(kw) do
    {:__block__, meta, [walk_quote_keyword(kw, quote_level, env)]}
  end

  defp walk_quote_arg(kw, quote_level, env) when is_list(kw) do
    walk_quote_keyword(kw, quote_level, env)
  end

  defp walk_quote_arg(other, quote_level, env), do: walk_quoted_data(other, quote_level, env)

  defp walk_quote_keyword(kw, quote_level, env) do
    Enum.map(kw, fn
      {key, value} = pair ->
        if AST.key_atom(key) == :do,
          do: {key, walk_quoted_data(value, quote_level, env)},
          else: pair

      other ->
        other
    end)
  end

  defp walk_quoted_data({:quote, meta, args} = node, quote_level, env) when is_list(args) do
    if quote_unquote_enabled?(args),
      do: {:quote, meta, walk_quote_args(args, quote_level + 1, env)},
      else: node
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
