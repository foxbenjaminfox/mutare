defmodule Mutare.Transform.Resolve.NodeIds do
  @moduledoc false

  alias Mutare.Transform.MetaKeys

  @nid_key MetaKeys.nid_key()

  @doc """
  The stable node id stamped by the resolve pre-pass, or `nil` for nodes with no metadata.
  """
  @spec get(Macro.t()) :: non_neg_integer() | nil
  def get({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, @nid_key)
  def get(_node), do: nil

  @doc """
  Stamp every metadata-bearing node with a unique, stable token.

  The token lets `Mutare.Transform.Overlap` compare node identity instead of relying on
  Sourceror ranges, which are not injective for every AST shape.
  """
  @spec stamp(Macro.t()) :: Macro.t()
  def stamp(ast) do
    {stamped, _next} =
      Macro.prewalk(ast, 0, fn
        {form, meta, args}, n when is_list(meta) ->
          {{form, [{@nid_key, n} | meta], args}, n + 1}

        node, n ->
          {node, n}
      end)

    stamped
  end
end
