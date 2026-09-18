defmodule Mutare.Transform.CleanPath do
  @moduledoc false

  # Eligibility for an **uninstrumented copy** of source code: the clean clause group of a
  # lifted function (`check_function/2`, relocated under a generated private name) or the
  # clean `:do` body of a clause that stays in place (`check_body/2`, same function).
  #
  # This is deliberately a positive syntax contract. An arbitrary macro can observe its
  # caller's function name, arity, or bindings, or run compile-time effects once per
  # expansion, even when its result looks like ordinary runtime code — and a copy that
  # fails to compile cannot be attributed to any mutant, so poison recovery could not
  # save the single build. Calls known to be functions may be copied; unknown calls may
  # not. The resolution stamps distinguish imported macros from the Kernel forms they
  # resemble.
  #
  # The walk threads **lexical scope**. An identifier that is not a bound variable can
  # expand a zero-arity macro (`on_undefined_variable: :warn`), so a name counts as a
  # variable only where a binding provably reaches it. The scope is an
  # under-approximation of Elixir's: a binding this walk loses only rejects a copy; a
  # binding it invented could accept a macro call. The rules, each checked against the
  # compiler: sibling operands never see each other's bindings, but those bindings
  # reach what follows; a scrutinee's or condition's bindings reach its clauses and what
  # follows; nothing escapes a clause body, `with`, `for`, `fn`, `try`, or the right side
  # of a short-circuit operator; arguments of an allowed macro bind nothing outward.
  #
  # A bare call that resolves to no import is a **local function** only when the module's
  # own `def`/`defp` inventory (`local_functions/1`) names it: a module cannot both define
  # and import one name/arity, nor define it as function and macro, so a compiling call
  # to an inventoried name is that function. Generated definitions, local macros, and
  # `use`-injected helpers are absent from the inventory and keep the instrumented path.
  # A copied call still enters the callee's ordinary dispatcher; eligibility never
  # authorizes bypassing a callee's selection.
  #
  # `super`, lexical directives, `quote`, nested modules, and explicit
  # function-environment or stack reflection keep the existing delivery path. Extending
  # the contract requires proving the corresponding copy behavior, not expanding macros
  # speculatively.
  #
  # Module-level definition callbacks are outside the FunctionPlan's vocabulary. As with
  # existing lifting, they see generated private definitions; this check cannot promise
  # transparency to an arbitrary @on_definition callback.

  alias Mutare.AST
  alias Mutare.Transform.{Aliases, Calls, ClauseAST, FunctionPlan, Imports, ModulePlan}

  defmodule Env do
    @moduledoc false

    # `self_call` is the `{name, arity}` being copied; `locals` the enclosing module's
    # positively known function inventory; `pure?` restricts the walk to operations that
    # cannot run user code (the recursion-bypass proof, see `pure_self_recursive?/1`).
    @enforce_keys [:self_call, :locals]
    defstruct [:self_call, :locals, pure?: false]
  end

  @typedoc "The `{name, arity}` pairs a module defines with a literal `def`/`defp`."
  @type locals :: MapSet.t({atom(), arity()})

  @typedoc """
  Why a copy was refused: the first construct outside the contract, as `{kind, detail}`.
  Read by the eligibility diagnostic (`bench/clean_eligibility.exs`); `kind` is one of
  `:unbound`, `:call`, `:remote`, `:form`, `:pattern`, `:bitstring`, `:reflection`,
  `:displaced`, `:impure`, or `:clause`.
  """
  @type reason :: {atom(), term()}
  @type verdict :: :ok | {:ineligible, reason()}

  @reflection_vars [:__ENV__, :__CALLER__, :__STACKTRACE__]

  # These are runtime functions, but explicitly expose the caller's stack or the
  # current function. Macros are already refused unless allow-listed below.
  @reflective_calls [
    {Process, :info},
    {:erlang, :process_info},
    {:erlang, :get_stacktrace},
    {Function, :info},
    {:erlang, :fun_info}
  ]

  # Kernel macros whose expansion depends only on their arguments, which are ordinary
  # expressions. `if`/`unless`, the short-circuit operators, `match?`, and sigils have
  # their own scoping or argument grammar below and are absent here on purpose.
  @kernel_macros [
    not: 1,
    !: 1,
    <>: 2,
    in: 2,
    ..: 2,
    ..//: 3,
    raise: 1,
    raise: 2,
    reraise: 2,
    reraise: 3,
    is_nil: 1,
    is_struct: 1,
    is_struct: 2,
    is_exception: 1,
    is_exception: 2,
    is_non_struct_map: 1,
    to_string: 1,
    to_charlist: 1,
    then: 2,
    tap: 2,
    # The path argument (`state.requests[ref]`) reads as the field and `Access` calls it
    # is written with, which is all this walk asks of it.
    put_in: 2,
    update_in: 2,
    get_and_update_in: 2,
    pop_in: 1
  ]

  # Remote macros whose expansion depends only on their arguments. `Logger`'s read the
  # caller's module, function, and line for metadata, which lifting already relocates
  # under a generated name; a clean copy reports the same kind of name.
  @remote_macros for(
                   level <-
                     [:debug, :info, :notice, :warning, :warn, :error] ++
                       [:critical, :alert, :emergency],
                   arity <- [1, 2],
                   do: {Logger, level, arity}
                 ) ++
                   [
                     {Logger, :log, 2},
                     {Logger, :log, 3},
                     {Integer, :is_odd, 1},
                     {Integer, :is_even, 1}
                   ]

  @pure_remote_macros [{Integer, :is_odd, 1}, {Integer, :is_even, 1}]

  # The subset that runs no user code: no protocol dispatch, no callback, no exception
  # constructor. Outside guards a nonliteral RHS of `in` calls `Enum.member?/2`, and a
  # custom `Enumerable` could change selection, so that familiar macro is excluded.
  @pure_kernel_macros [
    not: 1,
    !: 1,
    <>: 2,
    ..: 2,
    ..//: 3,
    is_nil: 1,
    is_struct: 1,
    is_struct: 2,
    is_exception: 1,
    is_exception: 2,
    is_non_struct_map: 1
  ]

  @kernel_sigils [
    :sigil_s,
    :sigil_S,
    :sigil_c,
    :sigil_C,
    :sigil_w,
    :sigil_W,
    :sigil_r,
    :sigil_R,
    :sigil_D,
    :sigil_T,
    :sigil_N,
    :sigil_U
  ]

  @pure_kernel [
    +: 1,
    +: 2,
    -: 1,
    -: 2,
    *: 2,
    /: 2,
    ++: 2,
    --: 2,
    ==: 2,
    !=: 2,
    ===: 2,
    !==: 2,
    <: 2,
    >: 2,
    <=: 2,
    >=: 2,
    abs: 1,
    bit_size: 1,
    byte_size: 1,
    ceil: 1,
    div: 2,
    elem: 2,
    floor: 1,
    hd: 1,
    is_atom: 1,
    is_binary: 1,
    is_bitstring: 1,
    is_boolean: 1,
    is_float: 1,
    is_function: 1,
    is_function: 2,
    is_integer: 1,
    is_list: 1,
    is_map: 1,
    is_map_key: 2,
    is_number: 1,
    is_pid: 1,
    is_port: 1,
    is_reference: 1,
    is_tuple: 1,
    length: 1,
    map_size: 1,
    max: 2,
    min: 2,
    put_elem: 3,
    rem: 2,
    round: 1,
    tl: 1,
    trunc: 1,
    tuple_size: 1
  ]

  @pure_erlang @pure_kernel ++
                 [element: 2, setelement: 3, map_get: 2, tuple_to_list: 1, list_to_tuple: 1]

  # Bitstring segment modifiers are matched by name: a user macro may define a custom
  # segment type, and its identifier looks exactly like these.
  @bitstring_modifiers [
    :integer,
    :float,
    :bits,
    :bitstring,
    :binary,
    :bytes,
    :utf8,
    :utf16,
    :utf32,
    :signed,
    :unsigned,
    :big,
    :little,
    :native
  ]

  # --- api --------------------------------------------------------------------

  @doc """
  The `{name, arity}` inventory of a module body's literal `def`/`defp` statements, with
  the lower arities their default arguments define. Definitions a macro or a
  module-level `for`/`if` generates are absent: the inventory states what is certain.
  """
  @spec local_functions([Macro.t()]) :: locals()
  def local_functions(statements) do
    # `ModulePlan.clause_signature/1` is the planner's reading of a static head: it declines
    # a dynamic name and the whole-head `def unquote(head)`, whose `:unquote` is no function.
    for statement <- statements,
        {_vis, name, arity} <- [ModulePlan.clause_signature(statement)],
        not ModulePlan.spliced?(hd(elem(statement, 2))),
        defaults = Enum.count(ClauseAST.head_args(statement), &match?({:\\, _, _}, &1)),
        lower <- (arity - defaults)..arity,
        into: MapSet.new(),
        do: {name, lower}
  end

  @doc """
  Whether every clause of a lifted group may be copied under a generated private name.
  Defaults stay on the public dispatcher, so a clause's `\\\\` contributes only its pattern.
  """
  @spec check_function(FunctionPlan.t(), locals()) :: verdict()
  def check_function(
        %FunctionPlan{signature: {_vis, name, arity}, clauses: clauses},
        locals \\ MapSet.new()
      ) do
    verdict(fn ->
      Enum.each(clauses, &clause(&1, %Env{self_call: {name, arity}, locals: locals}))
    end)
  end

  @doc """
  Whether one clause of a lifted group lies wholly inside the contract — head, guards, and
  every body block.

  `Mutare.Transform.LiftedEmit` asks this before it delivers a clause's guard mutants as
  `when` alternatives of **one** clause holding one copy of the raw body, where it used to
  emit a copy per mutant. The reason differs from a clean copy's. Nothing new is compiled
  here — the merge removes copies — so no unattributable compile failure is at stake. What
  changes is how many times the body's macros expand, and only a body made of known
  functions and the allow-listed macros is certain not to notice. An unknown macro keeps one
  clause per mutant, exactly as before.
  """
  @spec check_clause(FunctionPlan.t(), non_neg_integer(), locals()) :: verdict()
  def check_clause(
        %FunctionPlan{signature: {_vis, name, arity}, clauses: clauses},
        index,
        locals \\ MapSet.new()
      ) do
    verdict(fn ->
      clause(Enum.at(clauses, index), %Env{self_call: {name, arity}, locals: locals})
    end)
  end

  @doc """
  Whether one in-place clause's `:do` body may be duplicated inside its own function.
  The head, its defaults, and any `rescue`/`catch`/`else`/`after` block stay single; the
  head is still read, for the bindings it establishes.
  """
  @spec check_body(Macro.t(), locals()) :: verdict()
  def check_body(clause, locals \\ MapSet.new())

  def check_body({_vis, _meta, [head, blocks]} = clause, locals) when is_list(blocks) do
    verdict(fn ->
      {name, _meta, args} = ClauseAST.head_call(head)
      args = if is_list(args), do: args, else: []
      env = %Env{self_call: {name, length(args)}, locals: locals}
      bound = head_scope(args, ClauseAST.guards(clause), env)

      case Enum.find(blocks, fn {key, _body} -> AST.key_atom(key) == :do end) do
        {_key, body} -> expr(body, bound, env)
        nil -> reject({:clause, :no_do_block})
      end
    end)
  end

  def check_body(_clause, _locals), do: {:ineligible, {:clause, :bodiless}}

  @spec eligible?(FunctionPlan.t(), locals()) :: boolean()
  def eligible?(%FunctionPlan{} = plan, locals \\ MapSet.new()),
    do: check_function(plan, locals) == :ok

  @doc """
  Whether the original clauses recurse directly and contain only approved pure operations.

  Only the clean copy may use this result. A custom mutation can introduce side effects into
  an otherwise pure body, so it does not certify instrumented or replacement clauses. Fresh
  selector reads at ordinary entry points remain necessary for in-process Selector.put/1.
  """
  @spec pure_self_recursive?(FunctionPlan.t()) :: boolean()
  def pure_self_recursive?(%FunctionPlan{signature: {_vis, name, arity}, clauses: clauses}) do
    self_call = {name, arity}
    env = %Env{self_call: self_call, locals: MapSet.new(), pure?: true}

    verdict(fn -> Enum.each(clauses, &clause(&1, env)) end) == :ok and
      Enum.any?(clauses, fn {_vis, _meta, [_head | body]} ->
        {_body, recursive?} =
          walk_self_calls(body, self_call, false, fn node, _seen? -> {node, true} end)

        recursive?
      end)
  end

  @doc "Redirect full-arity local self calls in an eligible pure clean body."
  @spec redirect_self_calls(Macro.t(), {atom(), arity()}, atom(), [Macro.t()]) :: Macro.t()
  def redirect_self_calls(body, self_call, replacement, leading_args) do
    {body, _acc} =
      walk_self_calls(body, self_call, nil, fn {_name, meta, args}, acc ->
        {{replacement, meta, leading_args ++ args}, acc}
      end)

    body
  end

  # --- self-call traversal ------------------------------------------------------

  # Share effective-call traversal between detection and redirection. Only the pipe
  # stage receives the extra argument; calls nested in its arguments remain unpiped.
  # Materialize a matched stage's receiver before adding any leading arguments, so
  # those arguments precede the receiver just as they do for an ordinary self call.
  defp walk_self_calls({:|>, meta, [left, right]}, self_call, acc, fun) do
    {left, acc} = walk_self_calls(left, self_call, acc, fun)
    {right, acc} = walk_call_children(right, self_call, acc, fun)

    if self_call?(right, self_call, 1) do
      fun.(Macro.pipe(left, right, 0), acc)
    else
      {{:|>, meta, [left, right]}, acc}
    end
  end

  defp walk_self_calls(node, self_call, acc, fun) do
    {node, acc} = walk_call_children(node, self_call, acc, fun)
    if self_call?(node, self_call, 0), do: fun.(node, acc), else: {node, acc}
  end

  defp walk_call_children({form, meta, args}, self_call, acc, fun) when is_list(args) do
    {form, acc} = walk_self_calls(form, self_call, acc, fun)
    {args, acc} = walk_self_calls(args, self_call, acc, fun)
    {{form, meta, args}, acc}
  end

  defp walk_call_children({left, right}, self_call, acc, fun) do
    {left, acc} = walk_self_calls(left, self_call, acc, fun)
    {right, acc} = walk_self_calls(right, self_call, acc, fun)
    {{left, right}, acc}
  end

  defp walk_call_children(nodes, self_call, acc, fun) when is_list(nodes),
    do: Enum.map_reduce(nodes, acc, &walk_self_calls(&1, self_call, &2, fun))

  defp walk_call_children(node, _self_call, acc, _fun), do: {node, acc}

  defp self_call?({name, meta, args} = node, {name, arity}, extra)
       when is_list(args) and length(args) + extra == arity,
       do: is_nil(Calls.resolved_call(node)) and not Imports.kernel_displaced?(meta)

  defp self_call?(_node, _self_call, _extra), do: false

  # --- verdicts -----------------------------------------------------------------

  # The walk leaves by `throw` at the first construct outside the contract: a non-local
  # return from a deep recursive descent, caught here and nowhere else.
  defp verdict(walk) do
    walk.()
    :ok
  catch
    {:ineligible, _reason} = ineligible -> ineligible
  end

  @spec reject(reason()) :: no_return()
  defp reject(reason), do: throw({:ineligible, reason})

  # --- function clauses -----------------------------------------------------------

  defp clause({_vis, _meta, [head, blocks]} = clause, env) when is_list(blocks) do
    {_name, _meta, args} = ClauseAST.head_call(head)
    bound = head_scope(if(is_list(args), do: args, else: []), ClauseAST.guards(clause), env)

    # `rescue`/`catch`/`else`/`after` beside `do` are an implicit `try`.
    protected(blocks, bound, env)
  end

  # A bodiless header contributes only defaults, which stay on the dispatcher.
  defp clause({_vis, _meta, [_head]}, _env), do: :ok
  defp clause(_clause, _env), do: reject({:clause, :shape})

  defp head_scope(args, guards, env) do
    patterns =
      Enum.map(args, fn
        {:\\, _meta, [pattern, _default]} -> pattern
        pattern -> pattern
      end)

    bound = bind(MapSet.new(), patterns(patterns, MapSet.new(), env))
    Enum.each(guards, &guard(&1, bound, env))
    bound
  end

  # --- expressions ------------------------------------------------------------------

  # `expr/3` checks one expression under the names `bound` and returns the names it
  # binds for what follows (usually none).
  defp expr(value, _bound, _env)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: []

  defp expr(values, bound, env) when is_list(values), do: siblings(values, bound, env)
  defp expr({left, right}, bound, env), do: siblings([left, right], bound, env)

  defp expr({name, _meta, context}, bound, _env) when is_atom(name) and is_atom(context) do
    cond do
      name in [:_, :__MODULE__, :__DIR__] -> []
      name in @reflection_vars -> reject({:reflection, name})
      MapSet.member?(bound, name) -> []
      true -> reject({:unbound, name})
    end
  end

  defp expr({:__aliases__, _meta, _parts}, _bound, _env), do: []

  defp expr({:__block__, _meta, statements}, bound, env) do
    {_bound, escaping} =
      Enum.reduce(statements, {bound, []}, fn statement, {bound, escaping} ->
        new = expr(statement, bound, env)
        {bind(bound, new), new ++ escaping}
      end)

    escaping
  end

  defp expr({form, _meta, args} = node, bound, env) when is_atom(form) and is_list(args) do
    case construct(form, length(args)) do
      nil ->
        bare_call(node, bound, env)

      kind ->
        # The name alone does not make it Kernel's: an import may have displaced it.
        if Calls.kernel_call?(node),
          do: construct(kind, node, bound, env),
          else: reject({:displaced, {form, length(args)}})
    end
  end

  # A remote call. A receiver that is neither an alias nor an atom is dispatched at
  # runtime (`user.name`, `mod.fun(x)`, `__MODULE__.f(x)`), so it can never be a macro.
  defp expr({{:., _dot_meta, [receiver, fun]}, _meta, args} = node, bound, env)
       when is_atom(fun) and is_list(args) do
    case Calls.resolved_call(node) do
      {module, ^fun, _args, _rebuild} ->
        resolved_call(module, fun, args, bound, env)

      nil ->
        if env.pure?, do: reject({:impure, :dynamic_call})
        siblings([receiver | args], bound, env)
    end
  end

  defp expr({{:., _dot_meta, [callee]}, _meta, args}, bound, env) when is_list(args) do
    if env.pure?, do: reject({:impure, :dynamic_call})
    siblings([callee | args], bound, env)
  end

  defp expr(_node, _bound, _env), do: reject({:form, :unrecognized})

  # Operands evaluate under the same incoming scope; what each binds reaches only what
  # follows the whole expression.
  defp siblings(nodes, bound, env), do: Enum.flat_map(nodes, &expr(&1, bound, env))

  # Check under the incoming scope, and bind nothing outward.
  defp enclosed(node, bound, env) do
    _ = expr(node, bound, env)
    []
  end

  defp bind(bound, []), do: bound
  defp bind(bound, names), do: Enum.reduce(names, bound, &MapSet.put(&2, &1))

  # --- constructs --------------------------------------------------------------------

  # The forms with their own scoping or argument grammar, keyed by name and arity so a
  # name alone authorizes no arbitrary arity (`try(x, x)`, `if(x)`).
  defp construct(form, _arity) when form in [:{}, :%{}, :<<>>, :fn], do: form
  defp construct(form, arity) when form in [:with, :for] and arity >= 1, do: form
  defp construct(form, 1) when form in [:cond, :receive, :try, :&, :@], do: form
  defp construct(form, 2) when form in [:=, :|, :%, :case, :|>, :match?], do: form
  defp construct(form, 2) when form in [:if, :unless], do: :conditional
  defp construct(form, 2) when form in [:and, :or, :&&, :||], do: :short_circuit
  defp construct(form, 2) when form in @kernel_sigils, do: :sigil

  defp construct(form, arity) do
    if {form, arity} in @kernel_macros, do: :kernel_macro
  end

  defp construct(form, {_form, _meta, args}, bound, env) when form in [:{}, :%{}, :|],
    do: siblings(args, bound, env)

  defp construct(:%, {:%, _meta, [name, fields]}, bound, env) do
    unless struct_name?(name), do: reject({:form, :dynamic_struct})
    expr(fields, bound, env)
  end

  # The right side evaluates first; pins read the scope the match began under.
  defp construct(:=, {:=, _meta, [left, right]}, bound, env) do
    new = expr(right, bound, env)
    new ++ patterns([left], bound, env)
  end

  defp construct(:case, {:case, _meta, [scrutinee, blocks]}, bound, env) do
    new = expr(scrutinee, bound, env)
    clauses(only_block!(blocks, :do, :case), bind(bound, new), env)
    new
  end

  defp construct(:cond, {:cond, _meta, [blocks]}, bound, env) do
    blocks
    |> only_block!(:do, :cond)
    |> each_arrow(:cond, fn
      [condition], body -> enclosed(body, bind(bound, expr(condition, bound, env)), env)
      _heads, _body -> reject({:form, :cond})
    end)

    []
  end

  defp construct(:conditional, {_form, _meta, [condition, blocks]}, bound, env) do
    new = expr(condition, bound, env)
    inner = bind(bound, new)
    for {_key, body} <- blocks!(blocks, [:do, :else], :if), do: enclosed(body, inner, env)
    new
  end

  defp construct(:short_circuit, {_form, _meta, [left, right]}, bound, env) do
    new = expr(left, bound, env)
    enclosed(right, bind(bound, new), env)
    new
  end

  defp construct(:kernel_macro, {form, _meta, args}, bound, env) do
    if env.pure? and {form, length(args)} not in @pure_kernel_macros,
      do: reject({:impure, {form, length(args)}})

    Enum.each(args, &enclosed(&1, bound, env))
    []
  end

  defp construct(:match?, {:match?, _meta, [pattern, value]}, bound, env) do
    _ = head_names([pattern], bound, env)
    enclosed(value, bound, env)
  end

  defp construct(:sigil, {_sigil, _meta, [{:<<>>, _, parts}, modifiers]}, bound, env)
       when is_list(modifiers) do
    Enum.each(parts, &segment(&1, bound, env))
    []
  end

  defp construct(:sigil, _node, _bound, _env), do: reject({:form, :sigil})

  defp construct(:<<>>, {:<<>>, _meta, segments}, bound, env) do
    Enum.each(segments, &segment(&1, bound, env))
    []
  end

  # A module attribute read expands to the value at this point of the module body; a
  # copy is emitted at the same point. Its operand only looks like a variable.
  defp construct(:@, {:@, _meta, [{name, _attr_meta, context}]}, _bound, _env)
       when is_atom(name) and is_atom(context),
       do: []

  defp construct(:@, _node, _bound, _env), do: reject({:form, :attribute_write})

  # Piping is sugar for the call with its receiver first, and is checked as that call.
  # The stage's resolution stamp already counts the receiver in its arity.
  defp construct(:|>, {:|>, _meta, [left, right]}, bound, env) do
    piped =
      try do
        Macro.pipe(left, right, 0)
      rescue
        ArgumentError -> reject({:form, :pipe_target})
      end

    expr(piped, bound, env)
  end

  defp construct(:receive, {:receive, _meta, [blocks]}, bound, env) do
    if env.pure?, do: reject({:impure, :receive})

    for {key, value} <- blocks!(blocks, [:do, :after], :receive) do
      case AST.key_atom(key) do
        :do -> clauses(value, bound, env)
        :after -> timeout_clauses(value, bound, env)
      end
    end

    []
  end

  defp construct(:try, {:try, _meta, [blocks]}, bound, env), do: protected(blocks, bound, env)

  defp construct(:with, {:with, _meta, args}, bound, env) do
    {steps, blocks} = split_blocks!(args, :with)
    inner = Enum.reduce(steps, bound, &bind(&2, generator(&1, &2, env)))

    for {key, value} <- blocks!(blocks, [:do, :else], :with) do
      case AST.key_atom(key) do
        :do -> enclosed(value, inner, env)
        # `else` sees none of the bindings the steps made.
        :else -> clauses(value, bound, env)
      end
    end

    []
  end

  # `for` iterates through `Enumerable`/`Collectable`, whose implementations are user code.
  defp construct(:for, {:for, _meta, args}, bound, env) do
    if env.pure?, do: reject({:impure, :for})
    {steps, blocks} = split_blocks!(args, :for)
    inner = Enum.reduce(steps, bound, &bind(&2, generator(&1, &2, env)))
    options = blocks!(blocks, [:do, :into, :uniq, :reduce], :for)
    reduce? = Enum.any?(options, fn {key, _value} -> AST.key_atom(key) == :reduce end)

    for {key, value} <- options do
      case AST.key_atom(key) do
        :do when reduce? -> clauses(value, inner, env)
        :do -> enclosed(value, inner, env)
        _option -> enclosed(value, bound, env)
      end
    end

    []
  end

  defp construct(:fn, {:fn, _meta, arrows}, bound, env) do
    if env.pure?, do: reject({:impure, :closure})
    clauses(arrows, bound, env)
    []
  end

  # `&Mod.fun/2` and `&fun/2` name a function exactly as a call of that arity would;
  # any other capture is an expression over `&1`-style placeholders.
  defp construct(:&, {:&, _meta, [body]}, bound, env) do
    if env.pure?, do: reject({:impure, :closure})

    case body do
      {:/, _slash_meta, [{{:., _, _} = callee, call_meta, []}, arity]} ->
        expr({callee, call_meta, placeholders(arity)}, bound, env)

      # Through `expr/3`, not `bare_call/3`: `&is_nil/1` captures an allowed macro.
      {:/, _slash_meta, [{name, ref_meta, context}, arity]}
      when is_atom(name) and is_atom(context) ->
        expr({name, ref_meta, placeholders(arity)}, bound, env)

      placeholder when is_integer(placeholder) ->
        []

      body ->
        enclosed(body, bound, env)
    end
  end

  defp placeholders(arity) do
    case AST.unwrap_literal(arity) do
      arity when is_integer(arity) and arity >= 0 -> List.duplicate(nil, arity)
      _other -> reject({:form, :capture_arity})
    end
  end

  defp struct_name?({:__aliases__, _meta, _parts}), do: true
  defp struct_name?({:__MODULE__, _meta, context}) when is_atom(context), do: true
  defp struct_name?(name), do: is_atom(AST.unwrap_literal(name))

  # `try` (and a `def`'s implicit one): each block opens under the scope the `try` began
  # under, and none of their bindings escape.
  defp protected(blocks, bound, env) do
    for {key, value} <- blocks!(blocks, [:do, :rescue, :catch, :else, :after], :try) do
      case AST.key_atom(key) do
        key when key in [:do, :after] -> enclosed(value, bound, env)
        :rescue -> rescue_clauses(value, bound, env)
        key when key in [:catch, :else] -> clauses(value, bound, env)
      end
    end

    []
  end

  # `pattern <- value` (also a bitstring generator, whose `<-` sits in the last segment),
  # a plain match, or a filter; returns the names bound for the steps that follow.
  defp generator({:<-, _meta, [pattern, value]}, bound, env) do
    new = expr(value, bound, env)
    new ++ head_names([pattern], bind(bound, new), env)
  end

  defp generator({:<<>>, meta, segments}, bound, env) when segments != [] do
    case List.pop_at(segments, -1) do
      {{:<-, _arrow_meta, [last, value]}, leading} ->
        new = expr(value, bound, env)
        new ++ patterns([{:<<>>, meta, leading ++ [last]}], bind(bound, new), env)

      _no_generator ->
        expr({:<<>>, meta, segments}, bound, env)
    end
  end

  defp generator(step, bound, env), do: expr(step, bound, env)

  # --- calls ------------------------------------------------------------------------

  defp bare_call({name, meta, args} = node, bound, env) do
    case Calls.resolved_call(node) do
      {module, function, _args, _rebuild} ->
        resolved_call(module, function, args, bound, env)

      nil ->
        if local_function?(name, length(args), meta, env),
          do: siblings(args, bound, env),
          else: reject({:call, {name, length(args)}})
    end
  end

  # A call resolved to a module, written remotely or through an import. A function's
  # arguments are siblings; an allow-listed macro's bind nothing outward.
  defp resolved_call(module_key, function, args, bound, env) do
    arity = length(args)

    module =
      if is_atom(module_key) or Aliases.atoms?(module_key), do: Aliases.to_module(module_key)

    cond do
      is_nil(module) ->
        reject({:remote, {module_key, function, arity}})

      remote_function?(module, function, arity, env) ->
        siblings(args, bound, env)

      remote_macro?(module, function, arity, env) ->
        Enum.each(args, &enclosed(&1, bound, env))
        []

      true ->
        reject({:remote, {module_key, function, arity}})
    end
  end

  defp local_function?(name, arity, meta, %Env{} = env) do
    cond do
      {name, arity} == env.self_call -> true
      env.pure? -> not Imports.kernel_displaced?(meta) and pure_function?(Kernel, name, arity)
      MapSet.member?(env.locals, {name, arity}) -> true
      Imports.kernel_displaced?(meta) -> false
      true -> exported?(Kernel, name, arity)
    end
  end

  defp remote_function?(module, function, arity, %Env{pure?: true}),
    do: pure_function?(module, function, arity)

  defp remote_function?(module, function, arity, %Env{}), do: exported?(module, function, arity)

  defp remote_macro?(module, function, arity, %Env{pure?: pure?}) do
    allowed = if pure?, do: @pure_remote_macros, else: @remote_macros

    {module, function, arity} in allowed and Code.ensure_loaded?(module) and
      macro_exported?(module, function, arity)
  end

  defp pure_function?(module, function, arity),
    do:
      ((module == Kernel and {function, arity} in @pure_kernel) or
         (module == :erlang and {function, arity} in @pure_erlang)) and
        exported?(module, function, arity)

  defp exported?(module, function, arity),
    do:
      {module, function} not in @reflective_calls and Code.ensure_loaded?(module) and
        function_exported?(module, function, arity)

  # --- clauses ------------------------------------------------------------------------

  defp clauses(arrows, bound, env) do
    each_arrow(arrows, :clauses, fn heads, body ->
      enclosed(body, bind(bound, head_names(heads, bound, env)), env)
    end)
  end

  # A `receive … after` clause: the head is a timeout expression, not a pattern.
  defp timeout_clauses(arrows, bound, env) do
    each_arrow(arrows, :after, fn
      [timeout], body ->
        enclosed(timeout, bound, env)
        enclosed(body, bound, env)

      _heads, _body ->
        reject({:form, :after})
    end)
  end

  defp rescue_clauses(arrows, bound, env) do
    each_arrow(arrows, :rescue, fn
      [head], body -> enclosed(body, bind(bound, rescue_binding(head)), env)
      _heads, _body -> reject({:form, :rescue})
    end)
  end

  # Every clause must have the shape its reader expects: a clause skipped here would be
  # a clause copied unchecked.
  defp each_arrow(arrows, form, reader) do
    # `do: (acc -> acc + n)` parses as a literal-wrapped clause list.
    arrows = AST.unwrap_literal(arrows)
    unless is_list(arrows) and arrows != [], do: reject({:form, form})

    Enum.each(arrows, fn
      {:->, _meta, [heads, body]} when is_list(heads) -> reader.(heads, body)
      _other -> reject({:form, form})
    end)
  end

  defp rescue_binding({:in, _meta, [variable, exceptions]}) do
    unless exception_names?(exceptions), do: reject({:pattern, :rescue})
    rescue_binding(variable)
  end

  defp rescue_binding({:_, _meta, context}) when is_atom(context), do: []
  defp rescue_binding({name, _meta, context}) when is_atom(name) and is_atom(context), do: [name]

  defp rescue_binding(exceptions) do
    if exception_names?(exceptions), do: [], else: reject({:pattern, :rescue})
  end

  defp exception_names?({:__aliases__, _meta, _parts}), do: true
  defp exception_names?({:_, _meta, context}) when is_atom(context), do: true

  defp exception_names?(node) do
    case AST.unwrap_literal(node) do
      names when is_list(names) and names != [] -> Enum.all?(names, &exception_names?/1)
      name -> is_atom(name) and not is_nil(name)
    end
  end

  # The names a clause head binds for its body, after checking its guard under them.
  # `heads` is the argument list of `->`, whose lone element carries any `when`.
  defp head_names([{:when, _meta, parts}], bound, env) do
    {heads, [guard]} = Enum.split(parts, -1)
    names = patterns(heads, bound, env)
    guard(guard, bind(bound, names), env)
    names
  end

  defp head_names(heads, bound, env), do: patterns(heads, bound, env)

  # `when a when b` nests on the right; a guard binds nothing.
  defp guard({:when, _meta, alternatives}, bound, env),
    do: Enum.each(alternatives, &guard(&1, bound, env))

  defp guard(guard, bound, env), do: enclosed(guard, bound, env)

  # --- patterns -----------------------------------------------------------------------

  # The names a list of sibling patterns binds. `bound` is what a pin or a bitstring
  # size may read; a size may also read a name an earlier segment bound.
  defp patterns(nodes, bound, env),
    do: Enum.reduce(nodes, [], &pattern(&1, bound, &2, env))

  defp pattern(value, _bound, acc, _env)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: acc

  defp pattern(values, bound, acc, env) when is_list(values),
    do: Enum.reduce(values, acc, &pattern(&1, bound, &2, env))

  defp pattern({left, right}, bound, acc, env),
    do: pattern(right, bound, pattern(left, bound, acc, env), env)

  defp pattern({name, _meta, context}, _bound, acc, _env)
       when name in [:_, :__MODULE__] and is_atom(context),
       do: acc

  defp pattern({name, _meta, context}, _bound, acc, _env)
       when is_atom(name) and is_atom(context) do
    if name in @reflection_vars, do: reject({:reflection, name})
    [name | acc]
  end

  defp pattern({:^, _meta, [{name, _var_meta, context}]}, bound, acc, _env)
       when is_atom(name) and is_atom(context) do
    if MapSet.member?(bound, name), do: acc, else: reject({:unbound, name})
  end

  defp pattern({:__aliases__, _meta, _parts}, _bound, acc, _env), do: acc

  # A module attribute read is a compile-time constant; its operand only looks like a variable.
  defp pattern({:@, _meta, [{name, _attr_meta, context}]} = node, _bound, acc, _env)
       when is_atom(name) and is_atom(context) do
    if Calls.kernel_call?(node), do: acc, else: reject({:displaced, {:@, 1}})
  end

  defp pattern({:__block__, _meta, [literal]}, bound, acc, env),
    do: pattern(literal, bound, acc, env)

  defp pattern({form, _meta, args}, bound, acc, env) when form in [:{}, :%{}, :=, :|],
    do: pattern(args, bound, acc, env)

  defp pattern({:%, _meta, [name, fields]}, bound, acc, env) do
    acc = if struct_name?(name), do: acc, else: pattern(name, bound, acc, env)
    pattern(fields, bound, acc, env)
  end

  defp pattern({form, _meta, args} = node, bound, acc, env) when form in [:<>, :.., :..//] do
    unless Calls.kernel_call?(node), do: reject({:displaced, {form, length(args)}})
    pattern(args, bound, acc, env)
  end

  defp pattern({sign, _meta, [number]}, _bound, acc, _env) when sign in [:-, :+] do
    if is_number(AST.unwrap_literal(number)), do: acc, else: reject({:pattern, sign})
  end

  defp pattern({:<<>>, _meta, segments}, bound, acc, env),
    do: Enum.reduce(segments, acc, &segment_pattern(&1, bound, &2, env))

  defp pattern({sigil, _meta, [{:<<>>, _, parts}, modifiers]} = node, _bound, acc, _env)
       when sigil in @kernel_sigils and is_list(modifiers) do
    if Calls.kernel_call?(node) and Enum.all?(parts, &is_binary/1),
      do: acc,
      else: reject({:pattern, sigil})
  end

  defp pattern({form, _meta, _args}, _bound, _acc, _env), do: reject({:pattern, form})
  defp pattern(_node, _bound, _acc, _env), do: reject({:pattern, :unrecognized})

  # --- bitstrings -----------------------------------------------------------------------

  # String interpolation parses as a `Kernel.to_string/1` segment; `String.Chars` is a
  # protocol, so its implementation is user code.
  defp segment({:"::", _meta, [value, spec]}, bound, env) do
    case value do
      {{:., _, [Kernel, :to_string]}, _call_meta, [interpolated]} ->
        if env.pure?, do: reject({:impure, :interpolation})
        enclosed(interpolated, bound, env)

      value ->
        enclosed(value, bound, env)
    end

    segment_spec(spec, bound, env)
  end

  defp segment(value, bound, env), do: enclosed(value, bound, env)

  defp segment_pattern({:"::", _meta, [value, spec]}, bound, acc, env) do
    # A size reads the enclosing scope and the segments to its left. There a pin names an
    # outer variable (`size(^n - 1)`), which is all it could name in an expression.
    spec =
      Macro.prewalk(spec, fn
        {:^, _meta, [{name, _var_meta, context} = variable]}
        when is_atom(name) and is_atom(context) ->
          if MapSet.member?(bound, name), do: variable, else: reject({:unbound, name})

        node ->
          node
      end)

    segment_spec(spec, bind(bound, acc), env)
    pattern(value, bound, acc, env)
  end

  defp segment_pattern(value, bound, acc, env), do: pattern(value, bound, acc, env)

  defp segment_spec({:-, _meta, [left, right]}, bound, env) do
    segment_spec(left, bound, env)
    segment_spec(right, bound, env)
  end

  defp segment_spec({:*, _meta, [size, unit]}, _bound, _env) do
    unless is_integer(AST.unwrap_literal(size)) and is_integer(AST.unwrap_literal(unit)),
      do: reject({:bitstring, :size_unit})
  end

  defp segment_spec({:size, _meta, [size]}, bound, env), do: enclosed(size, bound, env)

  defp segment_spec({:unit, _meta, [unit]}, _bound, _env) do
    unless is_integer(AST.unwrap_literal(unit)), do: reject({:bitstring, :unit})
  end

  defp segment_spec({modifier, _meta, args}, _bound, _env)
       when modifier in @bitstring_modifiers and (is_atom(args) or args == []),
       do: :ok

  defp segment_spec(spec, _bound, _env) do
    unless is_integer(AST.unwrap_literal(spec)), do: reject({:bitstring, :modifier})
  end

  # --- block keywords ------------------------------------------------------------------

  # `for x <- xs, reduce: 0 do … end` carries its options and its `do` block as two
  # trailing keyword lists; `for x <- xs, into: %{}, do: …` as one.
  defp split_blocks!(args, form) do
    {blocks, steps} = args |> Enum.reverse() |> Enum.split_while(&keyword_blocks?/1)
    if blocks == [], do: reject({:form, form})
    {Enum.reverse(steps), blocks |> Enum.reverse() |> Enum.concat()}
  end

  defp keyword_blocks?(node) do
    is_list(node) and node != [] and
      Enum.all?(node, &(is_tuple(&1) and tuple_size(&1) == 2 and AST.key_atom(elem(&1, 0))))
  end

  defp only_block!(blocks, key, form) do
    case blocks!(blocks, [key], form) do
      [{_key, value}] -> value
      _other -> reject({:form, form})
    end
  end

  defp blocks!(blocks, allowed, form) do
    if is_list(blocks) and blocks != [] and
         Enum.all?(
           blocks,
           &(is_tuple(&1) and tuple_size(&1) == 2 and AST.key_atom(elem(&1, 0)) in allowed)
         ),
       do: blocks,
       else: reject({:form, form})
  end
end
