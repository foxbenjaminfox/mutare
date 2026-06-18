defmodule Mutare.Transform.NodeRange do
  @moduledoc """
  `Sourceror.get_range/1` with a correction for one upstream quirk that would
  otherwise corrupt a survivor's report diff.

  Sourceror sizes an atom literal as its name **plus one column for a colon** —
  right for a written atom (`:foo`, leading colon) and for a keyword-list key
  (`foo:`, trailing colon). But the three reserved-word atoms `true`/`false`/`nil`
  are written *bare*, with no colon, so their range comes back one column too
  wide. A textual patch over that range then eats the following character — e.g.
  `String.split(re, trim: true)` with the `true` swapped renders as
  `…, trim: false` (closing paren swallowed). `get/1` trims that phantom column.

  Only `Mutare.Report` reads the range, so the quirk is invisible at runtime: the
  metamutant is built from the AST, never the range. It corrupts only the diff a
  human reads for a surviving mutant. See NOTES "Sourceror range".
  """

  # Atoms written without any colon. A *keyword key* `true:`/`false:`/`nil:`
  # (`format: :keyword`) is written with the trailing colon, so Sourceror's count
  # is right there — the guard in `correct/2` excludes it.
  @bare_atoms [true, false, nil]

  @doc "Like `Sourceror.get_range/1`, correcting the bare-atom over-count."
  @spec get(Macro.t()) :: Sourceror.Range.t() | nil
  def get(node), do: node |> Sourceror.get_range() |> correct(node)

  defp correct(%Sourceror.Range{} = range, {:__block__, meta, [atom]})
       when atom in @bare_atoms do
    bare_written? = meta[:format] != :keyword and meta[:delimiter] in [nil, ""]

    if bare_written? and range.start[:line] == range.end[:line] do
      %{range | end: Keyword.update!(range.end, :column, &(&1 - 1))}
    else
      range
    end
  end

  defp correct(range, _node), do: range
end
