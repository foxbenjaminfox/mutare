defmodule Mutare.Mutators.DateTimeLiteral do
  @moduledoc """
  Calendar-sigil mutations: shift a date/time literal by one unit.

    * `~D[2020-01-01]` → `~D[2020-01-02]`   (+1 day)
    * `~T[12:00:00]`   → `~T[12:00:01]`     (+1 second)
    * `~N[…]`          → +1 day             (NaiveDateTime)
    * `~U[…Z]`         → +1 day             (DateTime, UTC)

  The temporal counterpart of `Mutare.Mutators.IntegerLiteral`'s off-by-one: a one-unit shift is the boundary nudge that catches `==`/`<`/`>` comparisons and date arithmetic a too-weak suite leaves unpinned.

  Why a shift, not a sentinel. Calendar sigils are validated at compile time (`~D[2020-13-99]` is a compile error), so a mutation must stay a valid date/time. The literal is parsed, shifted by one unit, and re-serialised, so the result is always a real calendar value.

  At the end of the sigil-supported year range that forward shift would itself be a compile error (`~D[9999-12-31]` renders as `10000-01-01`, which the sigil rejects — ISO 8601 wants four digits), so the nudge runs backwards there instead and the mutant is still a one-unit boundary shift. Each candidate is re-parsed before it is offered, which is the same check the compiler performs; a literal no direction can shift produces no mutant.

  Only non-interpolated sigils are reached (calendar sigils require literal content).
  """
  @behaviour Mutare.Mutator

  @sigils [:sigil_D, :sigil_T, :sigil_N, :sigil_U]

  # One day in seconds — the `:sigil_N`/`:sigil_U` shift, whose `add/2` defaults to seconds
  # (Date/Time shift by their own `+1` unit, a day / a second, below).
  @day_seconds 86_400

  # Forward first; backwards only where forward leaves the supported range (see `nudge/2`).
  @directions [1, -1]

  @impl Mutare.Mutator
  def name, do: :datetime

  @impl Mutare.Mutator
  def mutate({sigil, meta, [{:<<>>, bmeta, [content]}, modifiers]})
      when sigil in @sigils and is_binary(content) do
    case shift(sigil, content) do
      {:ok, shifted} -> [{sigil, meta, [{:<<>>, bmeta, [shifted]}, modifiers]}]
      # `from_iso8601` failure surfaces as `{:error, _}` here — no mutant rather
      # than invalid source.
      _ -> :skip
    end
  end

  def mutate(_node), do: :skip

  # Parse → ±1 unit → re-serialise. Any parse failure degrades to a non-`{:ok, …}`
  # value (handled above), so a sigil we can't read never produces invalid source.
  defp shift(:sigil_D, s) do
    with {:ok, d} <- Date.from_iso8601(s) do
      nudge(&Date.to_iso8601(Date.add(d, &1)), &Date.from_iso8601/1)
    end
  end

  defp shift(:sigil_T, s) do
    with {:ok, t} <- Time.from_iso8601(s) do
      nudge(&Time.to_iso8601(Time.add(t, &1)), &Time.from_iso8601/1)
    end
  end

  defp shift(:sigil_N, s) do
    with {:ok, n} <- NaiveDateTime.from_iso8601(s) do
      nudge(
        &NaiveDateTime.to_iso8601(NaiveDateTime.add(n, &1 * @day_seconds)),
        &NaiveDateTime.from_iso8601/1
      )
    end
  end

  defp shift(:sigil_U, s) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(s) do
      nudge(
        &DateTime.to_iso8601(DateTime.add(dt, &1 * @day_seconds)),
        &DateTime.from_iso8601/1
      )
    end
  end

  # Keep the first direction whose serialised form parses back. Re-parsing is exactly the
  # validation the sigil performs at compile time, so this is what keeps a boundary literal
  # (`~D[9999-12-31]` → `10000-01-01`) from becoming a mutant that can't compile — it takes
  # `9999-12-30` instead. Negative years are legal (`~D[-0001-12-31]` compiles), so only the
  # upper end is known to overflow today; the check is direction-agnostic so a future range
  # change can't reintroduce the bug. `nil` — no direction survives — reaches `mutate/1` as
  # "no mutant", the same as an unreadable literal.
  defp nudge(serialise, parse) do
    Enum.find_value(@directions, fn n ->
      shifted = serialise.(n)

      case parse.(shifted) do
        {:ok, _} -> {:ok, shifted}
        {:ok, _, _} -> {:ok, shifted}
        _ -> nil
      end
    end)
  end
end
