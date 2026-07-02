defmodule Mutare.CallsTest do
  use ExUnit.Case, async: true

  # `Mutare.Calls` is the author-facing facade over `Mutare.Transform.Calls`; the behaviour
  # itself is exercised in `Mutare.Transform.CallsTest`. The doctests here cover the published
  # contract as authors invoke it.
  doctest Mutare.Calls
end
