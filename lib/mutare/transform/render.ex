defmodule Mutare.Transform.Render do
  @moduledoc false

  # Sourceror rendering workarounds for the metamutant, kept apart from the
  # semantic transform. The metamutant is a throwaway build artifact that only
  # has to *compile* — these helpers exist solely to get `Sourceror.to_string`
  # to accept the rewritten tree. The diff report patches the original source and
  # never touches any of this.

  @doc """
  Render the annotated metamutant AST to source.

  Strips the analyzer's internal annotations, flips keyword-format keys back to
  plain atoms (a `Sourceror` formatter workaround), then renders. Metamutant
  only.
  """
  def to_source(ast) do
    ast
    |> strip_annotations()
    |> normalize_keyword_blocks()
    |> Sourceror.to_string()
  end

  @doc """
  Wrap a node in a single-expression block so it renders safely in any position.

  A bare `case` used directly as a `key: value` value crashes Sourceror's
  formatter; the surrounding `{:__block__, [], [node]}` makes it render fine
  everywhere (e.g. an in-place selector replacing a `def f, do: <expr>` value).
  """
  def block_wrap(node), do: {:__block__, [], [node]}

  # Sourceror represents a keyword-syntax key (`do:`, `else:`, but also `ms:`,
  # `env:`, any `key: value`) as `{:__block__, [format: :keyword], [key]}`. The
  # formatter crashes when such a pair's value becomes a `case`. We flip every
  # keyword-format key back to a plain atom key, which renders fine everywhere.
  defp normalize_keyword_blocks(ast) do
    Macro.prewalk(ast, fn
      {{:__block__, meta, [key]}, value} = pair when is_atom(key) and is_list(meta) ->
        if Keyword.get(meta, :format) == :keyword, do: {key, value}, else: pair

      other ->
        other
    end)
  end

  # Remove the analyzer's internal annotations before rendering. `:mutare`
  # (in-place candidates) and `:mutare_tag` (guard target references) are
  # bookkeeping that must never reach the source.
  defp strip_annotations(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, meta |> Keyword.delete(:mutare) |> Keyword.delete(:mutare_tag), args}

      other ->
        other
    end)
  end
end
