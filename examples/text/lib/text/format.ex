defmodule Text.Format do
  @moduledoc """
  Small text-formatting helpers: slugs, word counts, excerpts.

  A Mutare target built around String and Regex literals. The interesting
  survivors are the ones a transformation-heavy suite usually misses: an
  off-by-one in the truncation length, and the easily-overlooked separator
  literals that only matter for inputs the tests never feed in.
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
  def excerpt(text, max) when max > 0 do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max) <> "…"
    end
  end
end
