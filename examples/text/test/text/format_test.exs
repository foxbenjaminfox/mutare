defmodule Text.FormatTest do
  use ExUnit.Case

  alias Text.Format

  # A first, simple slug: internal punctuation and a trailing "!" exercise the
  # replace and the final trim("-"). There's no leading/trailing whitespace,
  # though, so the `String.trim()` in the middle of the pipe is never needed.
  test "slugify lower-cases and hyphenates" do
    assert Format.slugify("Hello, World!") == "hello-world"
  end

  # This fixture deliberately puts characters at the *edges* of the `a-z0-9`
  # class (a, z, 0, 9) and realistic separators (':' and '/'), so shrinking the
  # class by one (`a-z` → `a-y`) or growing it by one (`0-9` → `0-:`) changes the
  # slug and is killed. Only the two most exotic edges (a backtick below `a`, a
  # brace above `z`) survive — characters no realistic slug input contains.
  test "slugify keeps alphanumerics and collapses separator runs" do
    assert Format.slugify("Lazy Dog: 90% off! (a/z)") == "lazy-dog-90-off-a-z"
  end

  test "word_count counts whitespace-separated words" do
    assert Format.word_count("the quick brown fox") == 4
  end

  # excerpt/2 is tested only well below and well above the limit — never with a
  # string whose length is exactly `max`, so the `<= max` boundary survives. The
  # strings are all ASCII, too, so `String.length` and `byte_size` agree and that
  # swap survives as well.
  test "excerpt leaves short text untouched" do
    assert Format.excerpt("short", 20) == "short"
  end

  test "excerpt truncates long text and adds an ellipsis" do
    assert Format.excerpt("the quick brown fox", 9) == "the quick…"
  end
end
