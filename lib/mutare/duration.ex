defmodule Mutare.Duration do
  @moduledoc """
  Parse a human duration string (`"10m"`, `"90s"`, `"1h30m"`) into milliseconds.

  Used by the `:time_budget` option (`--time-budget`) — a wall-clock budget for the
  per-mutant phase (see `Mutare.Runner`). The grammar is deliberately tiny: one or
  more `<integer><unit>` segments, units `h`/`m`/`s`, in descending order, each
  optional but **at least one required**. Any non-negative integer is allowed in a
  segment (so `"90s"` and `"1h90m"` are fine — there is no 0–59 range check), and the
  total must be **positive**.

  A bare number with no unit (`"600"`) is rejected — the unit would be ambiguous — as
  is any other malformed input (wrong order, an unknown unit, a unit with no number).
  The parser never guesses; callers get an `{:error, reason}` they can surface verbatim.

      iex> Mutare.Duration.parse("1h30m")
      {:ok, 5_400_000}

      iex> Mutare.Duration.parse("90s")
      {:ok, 90_000}

      iex> match?({:error, _}, Mutare.Duration.parse("600"))
      true

      iex> match?({:error, _}, Mutare.Duration.parse("30s10m"))
      true
  """

  # Anchored and all-optional: each segment is `<digits><unit>`, in descending order,
  # so a wrong order / unknown unit / unit-without-number leaves input unconsumed and
  # `$` fails (→ no match → malformed). An all-optional match also accepts `""`, which
  # `from_captures/1` rejects as "no segment". Named groups so `Regex.named_captures`
  # always returns all three (positional `:all_but_first` drops *trailing* empties, so
  # `"10m"` would come back short).
  @grammar ~r/^(?:(?<h>\d+)h)?(?:(?<m>\d+)m)?(?:(?<s>\d+)s)?$/

  @malformed ~s(must be a duration string like "10m", "90s", or "1h30m" ) <>
               ~s{(units h/m/s, in descending order, at least one)}

  @spec parse(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    case Regex.named_captures(@grammar, input) do
      nil -> {:error, @malformed}
      captures -> from_captures(captures)
    end
  end

  def parse(_input), do: {:error, @malformed}

  # All three groups empty ⇒ the regex matched `""` (or an all-optional nothing): no
  # segment present, which the grammar allows but we don't.
  defp from_captures(%{"h" => "", "m" => "", "s" => ""}), do: {:error, @malformed}

  defp from_captures(%{"h" => hours, "m" => minutes, "s" => seconds}) do
    ms = unit(hours, 3_600_000) + unit(minutes, 60_000) + unit(seconds, 1_000)
    if ms > 0, do: {:ok, ms}, else: {:error, "must be a positive duration"}
  end

  defp unit("", _ms_each), do: 0
  defp unit(digits, ms_each), do: String.to_integer(digits) * ms_each
end
