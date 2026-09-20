defmodule Mutare.Transform.SelfCalls do
  @moduledoc false

  # Direct self-recursion inside a lifted group's relocated clean clauses
  # (`Mutare.Transform.LiftedEmit`). A clean clause that called its function by the public
  # name would re-enter the dispatcher at every step — a `:persistent_term` read and a
  # region decision per step, which on a small recursive function outweighs the body. So
  # every full-arity self-call in a clean clause is redirected to the clean name.
  #
  # No proof of purity is asked for. In a mutant run the selection is fixed for the life of
  # the VM, so the decision the dispatcher made on entry holds for the whole recursion. What
  # this gives up is an in-process `Mutare.Selector.put/1` issued *during* a recursion: the
  # steps already under way finish in the clean copy, and the next ordinary entry selects
  # afresh. A call at another arity, a capture, and every other callee keep their ordinary
  # entry points.
  #
  # A self-call is recognised by shape: the function's own name at its full arity, resolving
  # to no import (a module cannot both define and import one name/arity). The walk does not
  # ask whether the call sits in a macro's argument or a `quote`, where the rename reaches
  # code the macro treats as data. If that breaks the compile, the error lands in the clean
  # copy and poison recovery drops the region (`Mutare.Transform.CleanRegion`).
  #
  # The walk is pipe-aware: a pipe stage's arity includes its receiver, while calls nested in
  # its arguments keep their own. Without that, `n |> min(10)` inside `min/1` reads as
  # recursion and is redirected to a clean `min/2` that does not exist. A matched stage
  # becomes an ordinary call first, so leading arguments stay ahead of the receiver.

  alias Mutare.Transform.{Calls, Imports}

  @doc """
  Redirect every full-arity self-call of `self_call` in `body` to `replacement`, passing
  `leading_args` first. Returns the body and whether anything was redirected.
  """
  @spec redirect(Macro.t(), {atom(), arity()}, atom(), [Macro.t()]) :: {Macro.t(), boolean()}
  def redirect(body, self_call, replacement, leading_args) do
    walk(body, self_call, false, fn {_name, meta, args}, _redirected? ->
      {{replacement, meta, leading_args ++ args}, true}
    end)
  end

  defp walk({:|>, meta, [left, right]}, self_call, acc, fun) do
    {left, acc} = walk(left, self_call, acc, fun)
    {right, acc} = walk_children(right, self_call, acc, fun)

    if self_call?(right, self_call, 1) do
      fun.(Macro.pipe(left, right, 0), acc)
    else
      {{:|>, meta, [left, right]}, acc}
    end
  end

  defp walk(node, self_call, acc, fun) do
    {node, acc} = walk_children(node, self_call, acc, fun)
    if self_call?(node, self_call, 0), do: fun.(node, acc), else: {node, acc}
  end

  defp walk_children({form, meta, args}, self_call, acc, fun) when is_list(args) do
    {form, acc} = walk(form, self_call, acc, fun)
    {args, acc} = walk(args, self_call, acc, fun)
    {{form, meta, args}, acc}
  end

  defp walk_children({left, right}, self_call, acc, fun) do
    {left, acc} = walk(left, self_call, acc, fun)
    {right, acc} = walk(right, self_call, acc, fun)
    {{left, right}, acc}
  end

  defp walk_children(nodes, self_call, acc, fun) when is_list(nodes),
    do: Enum.map_reduce(nodes, acc, &walk(&1, self_call, &2, fun))

  defp walk_children(node, _self_call, acc, _fun), do: {node, acc}

  defp self_call?({name, meta, args} = node, {name, arity}, extra)
       when is_list(args) and length(args) + extra == arity,
       do: is_nil(Calls.resolved_call(node)) and not Imports.kernel_displaced?(meta)

  defp self_call?(_node, _self_call, _extra), do: false
end
