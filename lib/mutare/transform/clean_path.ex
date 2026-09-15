defmodule Mutare.Transform.CleanPath do
  @moduledoc false

  # Eligibility for an additional uninstrumented copy of an already-lifted function.
  # This is deliberately a positive syntax contract: an arbitrary macro can observe its
  # caller's function name, arity, or bindings, even when its result looks like ordinary
  # runtime code. Calls known to be functions can move; unknown calls cannot. The existing
  # resolution stamps distinguish imported macros from the Kernel forms they resemble.
  #
  # Keep defaults, super, closures/captures, lexical directives, and reflection on the
  # existing delivery path. Extending this list requires proving the corresponding
  # relocation behavior, not expanding macros speculatively. This predicate does not
  # authorize bypassing a callee's dispatcher or threading selection through recursion.
  #
  # Module-level definition callbacks are outside the FunctionPlan's vocabulary. As with
  # existing lifting, they see generated private definitions; this check cannot promise
  # transparency to an arbitrary @on_definition callback.

  alias Mutare.Transform.{Aliases, Calls, ClauseAST, FunctionPlan, Imports}

  @special_forms [
    {:__block__, :any},
    {:{}, :any},
    {:%{}, :any},
    {:=, 2},
    {:^, 1},
    {:|, 2},
    {:->, 2},
    {:when, 2},
    {:<-, 2},
    {:case, 2},
    {:cond, 1},
    {:receive, 1},
    {:try, 1},
    {:with, :any}
  ]

  @kernel_macros [if: 2, unless: 2, and: 2, or: 2, not: 1, &&: 2, ||: 2, !: 1, <>: 2, in: 2]

  @reflection_vars [:__ENV__, :__CALLER__, :__STACKTRACE__]

  # These are runtime functions, but explicitly expose the caller's stack or the
  # current function. Unrecognized macros are already rejected by exported?/3.
  @reflective_calls [
    {Process, :info},
    {:erlang, :process_info},
    {:erlang, :get_stacktrace},
    {Function, :info},
    {:erlang, :fun_info}
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

  @spec eligible?(FunctionPlan.t()) :: boolean()
  def eligible?(%FunctionPlan{signature: {_vis, name, arity}, clauses: clauses}) do
    Enum.all?(clauses, &clause?(&1, {name, arity}))
  end

  @doc """
  Whether the original clauses recurse directly and contain only approved pure operations.

  Only the clean copy may use this result. A custom mutation can introduce side effects into
  an otherwise pure body, so it does not certify instrumented or replacement clauses. Fresh
  selector reads at ordinary entry points remain necessary for in-process Selector.put/1.
  """
  @spec pure_self_recursive?(FunctionPlan.t()) :: boolean()
  def pure_self_recursive?(%FunctionPlan{signature: {_vis, name, arity}, clauses: clauses}) do
    self_call = {name, arity}

    Enum.all?(clauses, &clause?(&1, self_call, true)) and
      Enum.any?(clauses, fn {_vis, _meta, [_head, body]} ->
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

  defp clause?(clause, self_call, pure? \\ false)

  defp clause?({_vis, _meta, [head, body]}, self_call, pure?) do
    {_name, _meta, args} = ClauseAST.head_call(head)
    args = args || []

    {_args, variables} =
      Macro.prewalk(args, MapSet.new(), fn
        {name, _meta, context} = node, variables when is_atom(name) and is_atom(context) ->
          {node, MapSet.put(variables, name)}

        node, variables ->
          {node, variables}
      end)

    scope = %{call: self_call, variables: variables, pure?: pure?}

    safe?(args, scope) and
      safe?(ClauseAST.guards({:def, [], [head, body]}), scope) and
      safe?(body, scope)
  end

  # Bodiless headers declare defaults and therefore remain ineligible too.
  defp clause?(_clause, _self_call, _pure?), do: false

  defp safe?(value, _self_call)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: true

  defp safe?(values, self_call) when is_list(values),
    do: Enum.all?(values, &safe?(&1, self_call))

  defp safe?({left, right}, self_call),
    do: safe?(left, self_call) and safe?(right, self_call)

  # An unbound identifier can expand a zero-arity macro without parentheses. Accept
  # only bindings established by the function head; introducing new local bindings
  # conservatively leaves this first prototype on its existing instrumented path.
  defp safe?({name, _meta, context}, %{variables: variables})
       when is_atom(name) and is_atom(context),
       do:
         name not in @reflection_vars and
           (name in [:_, :__MODULE__, :__DIR__] or MapSet.member?(variables, name))

  defp safe?({:__aliases__, _meta, parts}, self_call),
    do: safe?(parts, self_call)

  defp safe?({:receive, _meta, _args}, %{pure?: true}), do: false

  # Outside guards, a nonliteral RHS of `in` calls Enum.member?/2. A custom
  # Enumerable implementation can change selection, so this familiar Kernel macro
  # does not certify pure recursion. Its clean copy still keeps ordinary entries.
  defp safe?({:in, _meta, _args}, %{pure?: true}), do: false

  defp safe?({:|>, _meta, [left, right]} = node, self_call),
    do: Calls.kernel_call?(node) and safe?(left, self_call) and call?(right, self_call, 1)

  defp safe?({name, _meta, args} = node, self_call) when is_atom(name) and is_list(args) do
    arity = length(args)

    if {name, arity} in @special_forms or {name, :any} in @special_forms or
         {name, arity} in @kernel_macros do
      Calls.kernel_call?(node) and safe?(args, self_call)
    else
      call?(node, self_call, 0)
    end
  end

  defp safe?(node, self_call), do: call?(node, self_call, 0)

  defp call?({name, _meta, args} = node, self_call, extra)
       when is_atom(name) and is_list(args) do
    arity = length(args) + extra

    callable? =
      case Calls.resolved_call(node) do
        {module, function, _args, _rebuild} ->
          allowed_call?(Aliases.to_module(module), function, arity, self_call)

        nil ->
          {name, arity} == self_call.call or
            (Calls.kernel_call?(node) and allowed_call?(Kernel, name, arity, self_call))
      end

    callable? and safe?(args, self_call)
  end

  defp call?({{:., _dot_meta, _target}, _meta, args} = node, self_call, extra)
       when is_list(args) do
    case Calls.resolved_call(node) do
      {module, function, _args, _rebuild} ->
        allowed_call?(Aliases.to_module(module), function, length(args) + extra, self_call) and
          safe?(args, self_call)

      nil ->
        false
    end
  end

  defp call?(_node, _self_call, _extra), do: false

  defp allowed_call?(module, function, arity, %{pure?: true}),
    do:
      ((module == Kernel and {function, arity} in @pure_kernel) or
         (module == :erlang and {function, arity} in @pure_erlang)) and
        exported?(module, function, arity)

  defp allowed_call?(module, function, arity, _scope), do: exported?(module, function, arity)

  defp exported?(nil, _function, _arity), do: false

  defp exported?(module, function, arity),
    do:
      {module, function} not in @reflective_calls and Code.ensure_loaded?(module) and
        function_exported?(module, function, arity)
end
