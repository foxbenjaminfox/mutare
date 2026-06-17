defmodule Auth.Policy do
  @moduledoc """
  Account sign-in policy: password strength and account lockout.

  A realistic Mutare target. Validation logic like this is exactly where test
  suites check the happy path and one or two obvious failures, then stop — so
  the off-by-one boundaries (`>= 8` vs `> 8`) and the `and`/`or` seams between
  rules go unverified. Mutare turns each of those gaps into a surviving mutant.
  """

  @min_length 8
  @max_attempts 5

  @doc """
  A password is strong enough when it is long enough *and* mixes character
  classes (an upper-case letter, a lower-case letter, and a digit).
  """
  def strong_password?(password) do
    String.length(password) >= @min_length and
      has_upper?(password) and has_lower?(password) and has_digit?(password)
  end

  @doc "Has the account exhausted its allowed sign-in attempts?"
  def locked?(failed_attempts) when failed_attempts >= @max_attempts, do: true
  def locked?(_failed_attempts), do: false

  @doc "How many attempts remain before lockout (never negative)."
  def attempts_left(failed_attempts) do
    max(@max_attempts - failed_attempts, 0)
  end

  @doc "Canonical form of an email address, for storage and comparison."
  def normalize_email(email) do
    email |> String.trim() |> String.downcase()
  end

  defp has_upper?(password), do: String.match?(password, ~r/[A-Z]/)
  defp has_lower?(password), do: String.match?(password, ~r/[a-z]/)
  defp has_digit?(password), do: String.match?(password, ~r/[0-9]/)
end
