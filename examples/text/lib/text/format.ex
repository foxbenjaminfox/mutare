defmodule Text.Format do
  @moduledoc """
  Small text-formatting helpers: slugs, word counts, excerpts.

  A Mutare target built around String and Regex literals. The headline survivor
  is a regex *range boundary*: the suite proves that runs of separators collapse
  to a hyphen and that `a`, `z`, `0`, and `9` are kept, but never tries a backtick
  or brace — so growing the class into those neighbours can slip through. The
  truncation length in `excerpt/2` hides the same kind of off-by-one, and the
  `String.trim/1` in `slugify/1` is redundant with the replacement and final
  hyphen trim — an equivalent mutant.
  """

  @doc "A URL-friendly slug: lower-cased, with runs of non-alphanumerics hyphenated."
  def slugify(text) do
    text
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc "The number of whitespace-separated words."
  def word_count(text) do
    text |> String.split() |> length()
  end

  @doc "Truncate to at most `max` characters, appending an ellipsis when cut."
  def excerpt(text, max) do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max) <> "…"
    end
  end
end
