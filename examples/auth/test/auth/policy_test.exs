defmodule Auth.PolicyTest do
  use ExUnit.Case

  alias Auth.Policy

  # The gaps below are deliberate — they are the *ordinary* gaps a competent but
  # not paranoid suite would leave, and each one becomes a Mutare survivor.

  test "accepts a strong password" do
    assert Policy.strong_password?("Secret123")
  end

  # "Ab1" is too short *and* would pass the character-class checks — so it tests
  # the length rule but never isolates a single missing class, nor the exact
  # `>= @min_length` boundary (no password of length 7 vs 8 is ever compared).
  test "rejects an obviously weak password" do
    refute Policy.strong_password?("Ab1")
  end

  # locked?/2 is checked well inside each side of the threshold (5 and 2), but
  # never *at* the boundary — so a mutant that shifts the limit to 4 survives.
  test "locks the account after too many failed attempts" do
    assert Policy.locked?(5)
    refute Policy.locked?(2)
  end

  # normalize_email/1, by contrast, is pinned down: the fixture has both
  # surrounding whitespace and mixed case, so dropping either String call (or
  # swapping up/down) changes the result and is killed.
  test "normalizes emails for storage and comparison" do
    assert Policy.normalize_email("  Alice@Example.COM ") == "alice@example.com"
  end

  # NOTE: attempts_left/1 has no test at all — the coverage probe will mark its
  # mutants as no-coverage and leave them out of the score.
end
