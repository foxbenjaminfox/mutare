defmodule Mutare.Site.Parenthesize do
  @moduledoc false
  # A Site's `mutated_code` is patched over its node's range (`Mutare.Report.patch/2`, and
  # whatever reads the JSON/SARIF range), so it must parse *there* as the one expression the
  # original was. A rendering that is right on its own may not:
  #
  #   * it binds looser than what it replaced — `!(a == b)` → `a == b` beside a `|>` reads
  #     `a == (b |> …)`; `to_string(a + b) <> "!"` → `a + b <> "!"`;
  #   * it starts with a sign right after one — the `0.75` of `-0.75` → `-0.25` reads `--0.25`;
  #   * it holds a `do`-block call the user had parenthesized, and the renderer, judging the
  #     replacement alone, dropped the parentheses — `case 0 + (if … end) do` → `0 - if … end`,
  #     which does not parse before the `case`'s own `do`, nor before a clause's `->`.
  #
  # The first two depend on where the node stands, and are decided by asking the parser rather
  # than a precedence table: write the bare replacement in the operator position the original
  # was written in (`Mutare.Transform.Resolve.OperandPositions`), beside a placeholder, and see
  # whether it parses to that operator applied to the replacement. So a statement, a call
  # argument, and a replacement that already fits (`a - b` for `a + b`, `x - -1`) stay bare.
  #
  # The third does not: the places a bare `do`-block call cannot stand are many (a block call's
  # head, a clause head, either side of an operator inside one), and the user's parentheses say
  # they were in one. So the replacement is parenthesized wherever it stands.
  #
  # A slot the user already parenthesized needs nothing: a node's range stops inside its own
  # parentheses (`Mutare.Transform.NodeRange`), so they are still there after the patch.
  #
  # Limit: a binary operator is modelled with spaces around it, as `mix format` writes it.
  # `a-0` → `a--1` in unformatted source is not caught.

  alias Mutare.Transform.Resolve.OperandPositions
  alias Mutare.Transform.WrittenPipe

  @placeholder "mutare_operand"

  @doc """
  `code` — the rendering of `mutated`, which replaces `original` — parenthesized if it would
  otherwise be read differently where `original` stands.
  """
  @spec in_position(String.t() | nil, Macro.t(), Macro.t()) :: String.t() | nil
  def in_position(nil, _original, _mutated), do: nil

  def in_position(code, original, mutated) do
    # A routed call written as a pipe stands where the pipe stood.
    written = WrittenPipe.written(original) || original

    if not parenthesized?(written) and
         (misread_in_position?(code, written) or dropped_block_parentheses?(mutated)),
       do: "(" <> code <> ")",
       else: code
  end

  defp parenthesized?({_form, meta, _args}) when is_list(meta),
    do: Keyword.has_key?(meta, :parens)

  defp parenthesized?(_node), do: false

  # --- the operator position ------------------------------------------------------------

  defp misread_in_position?(code, written) do
    with position when position != nil <- OperandPositions.get(written),
         {:ok, replacement} <- parse(code) do
      parse(write(position, code)) != {:ok, expected(position, replacement)}
    else
      _unconstrained -> false
    end
  end

  defp write({:not, 1, 0}, code), do: "not #{code}"
  defp write({operator, 1, 0}, code), do: "#{operator}#{code}"
  defp write({operator, 2, 0}, code), do: "#{code} #{operator} #{@placeholder}"
  defp write({operator, 2, 1}, code), do: "#{@placeholder} #{operator} #{code}"
  defp write(:dot_receiver, code), do: "#{code}.#{@placeholder}"

  defp expected({operator, 1, 0}, replacement), do: {operator, [], [replacement]}
  defp expected({operator, 2, 0}, replacement), do: {operator, [], [replacement, placeholder()]}
  defp expected({operator, 2, 1}, replacement), do: {operator, [], [placeholder(), replacement]}

  defp expected(:dot_receiver, replacement),
    do: {{:., [], [replacement, String.to_atom(@placeholder)]}, [], []}

  defp placeholder, do: {String.to_atom(@placeholder), [], nil}

  defp parse(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> {:ok, Macro.prewalk(ast, &Macro.update_meta(&1, fn _meta -> [] end))}
      {:error, _reason} -> :error
    end
  end

  # --- a `do`-block call the user parenthesized ---------------------------------------------

  # The replacement's own node included: when it was an operand of the original
  # (`!(if … end)` → `if … end`), its parentheses lay inside the range and went with it. When it
  # stands in the original's own slot, `in_position/3` never gets here — that slot is
  # parenthesized, and stays so. Only an expression can be parenthesized — not a clause, nor a
  # definition.
  defp dropped_block_parentheses?({form, _meta, _args})
       when form in [:->, :def, :defp, :defmacro, :defmacrop],
       do: false

  defp dropped_block_parentheses?({_form, _meta, args} = mutated) when is_list(args) do
    {_mutated, found?} =
      Macro.prewalk(mutated, false, fn node, found? ->
        {node, found? or parenthesized_block?(node)}
      end)

    found?
  end

  defp dropped_block_parentheses?(_node), do: false

  defp parenthesized_block?({form, meta, args})
       when is_atom(form) and is_list(meta) and is_list(args),
       do: Keyword.has_key?(meta, :parens) and Keyword.has_key?(meta, :do)

  defp parenthesized_block?(_node), do: false
end
