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
  # A self-call is recognised by shape alone: the function's own name at its full arity, called
  # bare. Elixir rejects a bare call that an import and a local function could both answer
  # ("imported M.f/1 conflicts with local function"), so in a module that compiles, no import
  # answers it. That holds for a `Kernel` name too: a module defining `max/2` has excluded
  # `Kernel`'s. Argument routes
  # preserve opaque syntax, including raw values in keyword refinements. Quoted bodies
  # are data: only an executable quote's option values and live unquote expressions can
  # contain executable self-calls. Renaming quoted calls can silently change returned data
  # even when both copies compile.
  # Definitions are separate scopes: their heads are declarations, and their bodies'
  # calls belong to the new scope. Leave the entire construct at its ordinary entry
  # points. Quoted definitions still admit live unquotes in the enclosing function.
  #
  # Resolve has already expanded executable pipes to calls, so a stage's arity includes
  # its receiver. Quoted pipes remain data, and their spelling is preserved too.

  alias Mutare.Transform.{Calls, KeywordRouting, Meta, QuoteStructure}

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

  defp walk(node, level, self_call, acc, fun) do
    if Meta.skipped?(node),
      do: {node, acc},
      else: do_walk(node, level, self_call, acc, fun)
  end

  # `level` is 0 in live code and 1 in quoted data; `QuoteStructure` says what crosses.
  defp do_walk({:quote, meta, args}, 0, self_call, acc, fun) when is_list(args) do
    {parts, rebuild} = QuoteStructure.parts(args)

    {values, acc} =
      Enum.map_reduce(parts, acc, fn
        {value, :live}, acc -> walk(value, 0, self_call, acc, fun)
        {value, :quoted}, acc -> walk(value, 1, self_call, acc, fun)
        {value, :inert}, acc -> {value, acc}
      end)

    {{:quote, meta, rebuild.(values)}, acc}
  end

  # Executable Kernel pipes were desugared by Resolve. A surviving pipe can be withheld
  # syntax with no resolution at all: neither its operator nor its RHS arity is known.
  # Leave it intact unless resolution positively identified a displaced operator, whose
  # operands can be walked as ordinary calls.
  defp do_walk({:|>, _meta, _args} = pipe, 0, self_call, acc, fun) do
    if Calls.kernel_call?(pipe),
      do: {pipe, acc},
      else: walk_routed_children(pipe, acc, &walk(&1, 0, self_call, &2, fun))
  end

  defp do_walk(node, 0, self_call, acc, fun) do
    {node, acc} = walk_routed_children(node, acc, &walk(&1, 0, self_call, &2, fun))
    if self_call?(node, self_call), do: fun.(node, acc), else: {node, acc}
  end

  defp do_walk(node, 1, self_call, acc, fun) do
    case QuoteStructure.quoted(node) do
      {:escape, arg, rebuild} ->
        {arg, acc} = walk(arg, 0, self_call, acc, fun)
        {rebuild.(arg), acc}

      {:options, options, rebuild} ->
        {options, acc} = walk(options, 1, self_call, acc, fun)
        {rebuild.(options), acc}

      :inert ->
        {node, acc}

      :data ->
        walk_children(node, acc, &walk(&1, 1, self_call, &2, fun))
    end
  end

  defp walk_routed_children(node, acc, fun) do
    if definition?(node), do: {node, acc}, else: do_walk_routed_children(node, acc, fun)
  end

  @definitions ~w(defmodule defprotocol defimpl def defp defmacro defmacrop defguard defguardp defdelegate)a

  # mutare:ignore[guard_drop] equivalent — a variable named `def` would read as a definition, and be left as it is either way: it has no children
  defp definition?({form, _meta, args} = node) when is_list(args) do
    case Calls.resolved_call(node) do
      {[:Kernel], name, _args, _rebuild} -> name in @definitions
      nil -> form in @definitions and Calls.kernel_call?(node)
      _other -> false
    end
  end

  defp definition?(_node), do: false

  defp do_walk_routed_children({form, meta, args} = node, acc, fun) do
    case Meta.routing(meta) do
      treatments when is_list(treatments) ->
        {form, acc} = fun.(form, acc)

        {args, acc} =
          Enum.zip(args, treatments)
          |> Enum.map_reduce(acc, fn {arg, treatment}, acc ->
            walk_argument(arg, treatment, acc, fun)
          end)

        {{form, meta, args}, acc}

      nil ->
        walk_children(node, acc, fun)

      :skip ->
        {node, acc}
    end
  end

  defp do_walk_routed_children(node, acc, fun), do: walk_children(node, acc, fun)

  defp walk_argument(arg, :raw, acc, _fun), do: {arg, acc}
  defp walk_argument(arg, {:hosted, _hosts}, acc, _fun), do: {arg, acc}

  # A quote has no executable call at its root; preserve its quote/unquote scope walk.
  defp walk_argument({:quote, _, _} = arg, :interior, acc, fun), do: fun.(arg, acc)
  defp walk_argument(arg, :interior, acc, fun), do: walk_routed_children(arg, acc, fun)

  defp walk_argument(arg, {:keyed, _, _} = treatment, acc, fun),
    do: walk_keyword(arg, treatment, acc, fun)

  defp walk_argument(arg, {:keyword, _} = treatment, acc, fun),
    do: walk_keyword(arg, treatment, acc, fun)

  defp walk_argument(arg, _treatment, acc, fun), do: fun.(arg, acc)

  defp walk_keyword(arg, treatment, acc, fun) do
    case KeywordRouting.decode(arg, treatment) do
      {:pairs, pairs, rewrap} ->
        {pairs, acc} =
          Enum.map_reduce(pairs, acc, fn {{key, key_treatment}, {value, value_treatment}}, acc ->
            {key, acc} = walk_argument(key, key_treatment, acc, fun)
            {value, acc} = walk_argument(value, value_treatment, acc, fun)
            {{key, value}, acc}
          end)

        {rewrap.(pairs), acc}

      {:whole, fallback} ->
        walk_argument(arg, fallback, acc, fun)
    end
  end

  defp walk_children({form, meta, args}, acc, fun) do
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

  defp self_call?({name, _meta, args}, {name, arity}) when is_list(args),
    do: length(args) == arity

  defp self_call?(_node, _self_call), do: false
end
