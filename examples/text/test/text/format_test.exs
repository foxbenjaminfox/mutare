defmodule Text.FormatTest do
  use ExUnit.Case

  alias Text.Format

  # The fixture has internal punctuation and a trailing "!", so the replace and
  # the final trim("-") are both exercised — but there is no leading punctuation
  # and no run of separators long enough to tell `+` from a single match, so
  # some regex/literal mutants survive.
  test "slugify lower-cases and hyphenates" do
    assert Format.slugify("Hello, World!") == "hello-world"
  end

  test "word_count counts whitespace-separated words" do
    assert Format.word_count("the quick brown fox") == 4
  end

  # excerpt/2 is tested only well below and well above the limit — never with a
  # string whose length is exactly `max` or `max + 1`, so the `<= max` boundary
  # and the slice length survive.
  test "excerpt leaves short text untouched" do
    assert Format.excerpt("short", 20) == "short"
  end

  test "excerpt truncates long text and adds an ellipsis" do
    assert Format.excerpt("the quick brown fox", 9) == "the quick…"
  end
end
