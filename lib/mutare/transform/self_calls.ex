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
  # classify macro arguments. Quoted bodies, however, are data: only quote option values
  # and live unquote expressions can contain executable self-calls. Renaming quoted calls
  # can silently change returned data even when both copies compile.
  #
  # Resolve has already expanded executable pipes to calls, so a stage's arity includes
  # its receiver. Quoted pipes remain data, and their spelling is preserved too.

  alias Mutare.AST
  alias Mutare.Transform.Analyze.QuoteEscape
  alias Mutare.Transform.{Calls, Imports, Meta}

  @doc """
  Redirect executable full-arity self-calls of `self_call` in `body` to `replacement`,
  passing `leading_args` first. Returns the body and whether anything was redirected.
  """
  @spec redirect(Macro.t(), {atom(), arity()}, atom(), [Macro.t()]) :: {Macro.t(), boolean()}
  def redirect(body, self_call, replacement, leading_args) do
    walk(body, 0, self_call, false, fn {_name, _meta, args} = call, _redirected? ->
      # The redirected call is generated: with `leading_args` ahead of the user's own, its
      # argument 0 is no longer what they piped in, so it is not spelled as their pipe.
      {_name, meta, _args} = Meta.drop_written_pipe(call)
      {{replacement, meta, leading_args ++ args}, true}
    end)
  end

  defp walk({:quote, meta, args}, level, self_call, acc, fun) when is_list(args) do
    enabled? = QuoteEscape.quote_unquote_enabled?(args)

    {args, acc} =
      Enum.map_reduce(args, acc, &walk_quote_arg(&1, level, enabled?, self_call, &2, fun))

    {{:quote, meta, args}, acc}
  end

  defp walk({form, meta, [arg]}, 1, self_call, acc, fun)
       when form in [:unquote, :unquote_splicing] do
    {arg, acc} = walk(arg, 0, self_call, acc, fun)
    {{form, meta, [arg]}, acc}
  end

  # Even stacked unquotes in a nested quote remain data for the outer quote.
  defp walk({form, _meta, [_arg]} = node, level, _self_call, acc, _fun)
       when form in [:unquote, :unquote_splicing] and level > 1,
       do: {node, acc}

  # Executable Kernel pipes were desugared by Resolve. A surviving pipe can be withheld
  # syntax with no resolution at all: neither its operator nor its RHS arity is known.
  # Leave it intact unless resolution positively identified a displaced operator, whose
  # operands can be walked as ordinary calls.
  defp walk({:|>, _meta, _args} = pipe, 0, self_call, acc, fun) do
    if Calls.kernel_call?(pipe),
      do: {pipe, acc},
      else: walk_children(pipe, acc, &walk(&1, 0, self_call, &2, fun))
  end

  defp walk(node, level, self_call, acc, fun) do
    {node, acc} = walk_children(node, acc, &walk(&1, level, self_call, &2, fun))
    if level == 0 and self_call?(node, self_call), do: fun.(node, acc), else: {node, acc}
  end

  defp walk_quote_arg({:__block__, meta, [kw]}, level, enabled?, self_call, acc, fun)
       when is_list(kw) do
    {kw, acc} = walk_quote_arg(kw, level, enabled?, self_call, acc, fun)
    {{:__block__, meta, [kw]}, acc}
  end

  defp walk_quote_arg(kw, level, enabled?, self_call, acc, fun) when is_list(kw),
    do: Enum.map_reduce(kw, acc, &walk_quote_arg(&1, level, enabled?, self_call, &2, fun))

  defp walk_quote_arg({key, value} = pair, level, enabled?, self_call, acc, fun) do
    case AST.key_atom(key) do
      :do when enabled? ->
        {value, acc} = walk(value, level + 1, self_call, acc, fun)
        {{key, value}, acc}

      :do ->
        {pair, acc}

      _option ->
        {value, acc} = walk(value, level, self_call, acc, fun)
        {{key, value}, acc}
    end
  end

  defp walk_quote_arg(other, _level, _enabled?, _self_call, acc, _fun), do: {other, acc}

  defp walk_children({form, meta, args}, acc, fun) when is_list(args) do
    {form, acc} = fun.(form, acc)
    {args, acc} = fun.(args, acc)
    {{form, meta, args}, acc}
  end

  defp walk_children({left, right}, acc, fun) do
    {left, acc} = fun.(left, acc)
    {right, acc} = fun.(right, acc)
    {{left, right}, acc}
  end

  defp walk_children(nodes, acc, fun) when is_list(nodes),
    do: Enum.map_reduce(nodes, acc, fun)

  defp walk_children(node, acc, _fun), do: {node, acc}

  defp self_call?({name, meta, args} = node, {name, arity})
       when is_list(args) and length(args) == arity,
       do: is_nil(Calls.resolved_call(node)) and not Imports.kernel_displaced?(meta)

  defp self_call?(_node, _self_call), do: false
end
