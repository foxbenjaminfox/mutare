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

  # authorize/2 succeeds on an unlocked account with a strong password. The
  # fixture's email ("ada@example.com") has no upper-case letter, so it would fail
  # `strong_password?/1` — which is exactly what kills the `{email, password}` swap
  # in the `with` chain: swapped, the email is checked as the password and rejected.
  test "authorize accepts an unlocked account with a strong password" do
    assert Policy.authorize({"ada@example.com", "Sup3rSecret1"}, 0) == {:ok, "ada@example.com"}
  end

  # The denied paths exercise the with/else seam — a locked account and a weak
  # password — but only loosely (they don't pin which rule did the rejecting).
  test "authorize denies a locked account or a weak password" do
    assert Policy.authorize({"ada@example.com", "Sup3rSecret1"}, 9) == {:error, :denied}
    assert Policy.authorize({"ada@example.com", "weak"}, 0) == {:error, :denied}
  end

  # NOTE: attempts_left/1 has no test at all — the coverage probe will mark its
  # mutants as no-coverage and leave them out of the score.
end
