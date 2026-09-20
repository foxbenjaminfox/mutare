defmodule Mutare.Transform.Resolve.OperandPositions do
  @moduledoc false
  # Stamps every operand with the operator position it was written in, so a `Mutare.Site` —
  # which sees only its own node — can tell whether its replacement needs parentheses there
  # (`Mutare.Site.Parenthesize`). A Site's text is patched over the node's range, and the text
  # that stood there parsed as one operand; a replacement that binds looser, or that starts with
  # a sign right after one, does not.
  #
  # A position is `{operator, arity, index}` for an operand of a unary or binary operator, or
  # `:dot_receiver` for what a `.` is applied to (`recv.field`, `recv.fun(…)`, `callee.(…)`).
  # Every other place a node can stand — a statement, a call argument, a collection element, a
  # keyword value — delimits its expression without help, and is left unstamped.
  #
  # The stamp describes the **source**, which is what a Site patches: a node a later pass moves
  # (a routed pipe's left side, made argument 0) still reports where the user wrote it.

  alias Mutare.Transform.MetaKeys

  @key MetaKeys.operand_of_key()

  @type position :: {atom(), 1 | 2, 0 | 1} | :dot_receiver

  @doc "The position `node` was written in, or `nil` when it is not an operator's operand."
  @spec get(Macro.t()) :: position() | nil
  def get({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, @key)
  def get(_node), do: nil

  @spec stamp(Macro.t()) :: Macro.t()
  def stamp(ast), do: Macro.prewalk(ast, &stamp_operands/1)

  defp stamp_operands({{:., dot_meta, [receiver | name]}, meta, args}) when is_list(args),
    do: {{:., dot_meta, [put(receiver, :dot_receiver) | name]}, meta, args}

  # A clause is no operator application, whatever `Macro.operator?/2` says of `->`.
  defp stamp_operands({:->, _meta, _args} = clause), do: clause

  # (`:.` is an operator to `Macro.operator?/2`, and its node is the head of the call the clause
  # above already read — receiver on the left, a bare name on the right.)
  defp stamp_operands({form, meta, [_ | _] = args} = node)
       when is_atom(form) and form != :. and is_list(meta) do
    arity = length(args)

    if arity <= 2 and Macro.operator?(form, arity) do
      operands =
        for {operand, index} <- Enum.with_index(args),
            do: put(operand, {form, arity, index})

      {form, meta, operands}
    else
      node
    end
  end

  defp stamp_operands(node), do: node

  defp put({form, meta, args}, position) when is_list(meta),
    do: {form, Keyword.put(meta, @key, position), args}

  defp put(node, _position), do: node
end
