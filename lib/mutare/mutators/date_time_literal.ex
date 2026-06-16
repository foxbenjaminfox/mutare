defmodule Mutare.Mutators.DateTimeLiteral do
  @moduledoc """
  Calendar-sigil mutations: shift a date/time literal by one unit.

    * `~D[2020-01-01]` → `~D[2020-01-02]`   (+1 day)
    * `~T[12:00:00]`   → `~T[12:00:01]`     (+1 second)
    * `~N[…]`          → +1 day             (NaiveDateTime)
    * `~U[…Z]`         → +1 day             (DateTime, UTC)

  The temporal counterpart of `Mutare.Mutators.Literal`'s integer off-by-one: a
  one-unit shift is the boundary nudge that catches `==`/`</`>` comparisons and
  date arithmetic a too-weak suite leaves unpinned.

  **Why a shift, not a sentinel.** Calendar sigils are *validated at compile time*
  (`~D[2020-13-99]` is a compile error), so a mutation must stay a valid date/time
  — emitting garbage would poison the single build. We parse the literal with the
  stdlib at transform time, add one unit, and re-serialise, so the result is always
  a real calendar value. A literal we cannot parse (it should not happen — the
  compiler would have rejected it — but defensively) yields no mutant.

  In-place and compile-safe; only non-interpolated sigils are reached (calendar
  sigils require literal content, so the operand is always a single binary).
  """
  @behaviour Mutare.Mutator

  @sigils [:sigil_D, :sigil_T, :sigil_N, :sigil_U]

  @impl Mutare.Mutator
  def name, do: :datetime

  @impl Mutare.Mutator
  def mutate({sigil, meta, [{:<<>>, bmeta, [content]}, modifiers]})
      when sigil in @sigils and is_binary(content) do
    case shift(sigil, content) do
      {:ok, shifted} -> [{sigil, meta, [{:<<>>, bmeta, [shifted]}, modifiers]}]
      # `from_iso8601` failure surfaces as `{:error, _}` (or `:error`) here — either
      # way, no mutant rather than invalid source.
      _ -> :skip
    end
  end

  def mutate(_node), do: :skip

  # Parse → +1 unit → re-serialise. Any parse failure degrades to a non-`{:ok, …}`
  # value (handled above), so a sigil we can't read never produces invalid source.
  defp shift(:sigil_D, s) do
    with {:ok, d} <- Date.from_iso8601(s), do: {:ok, Date.to_iso8601(Date.add(d, 1))}
  end

  defp shift(:sigil_T, s) do
    with {:ok, t} <- Time.from_iso8601(s), do: {:ok, Time.to_iso8601(Time.add(t, 1))}
  end

  defp shift(:sigil_N, s) do
    with {:ok, n} <- NaiveDateTime.from_iso8601(s),
         do: {:ok, NaiveDateTime.to_iso8601(NaiveDateTime.add(n, 86_400))}
  end

  defp shift(:sigil_U, s) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(s),
         do: {:ok, DateTime.to_iso8601(DateTime.add(dt, 86_400))}
  end

  # `from_iso8601` returns `{:error, reason}` on failure; collapse anything that is
  # not an `{:ok, …}` shift to `:error`.
  defp shift(_sigil, _content), do: :error
end
