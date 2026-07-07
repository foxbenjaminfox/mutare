defmodule Mutare.DurationTest do
  use ExUnit.Case, async: true

  alias Mutare.Duration

  doctest Mutare.Duration

  describe "parse/1 — well-formed durations" do
    test "a single segment for each unit" do
      assert Duration.parse("1h") == {:ok, 3_600_000}
      assert Duration.parse("1m") == {:ok, 60_000}
      assert Duration.parse("1s") == {:ok, 1_000}
    end

    test "combined segments sum, in descending order" do
      assert Duration.parse("1h30m") == {:ok, 5_400_000}
      assert Duration.parse("2m30s") == {:ok, 150_000}
      assert Duration.parse("1h2m3s") == {:ok, 3_723_000}
    end

    test "any integer is allowed in a segment — no 0-59 range check" do
      assert Duration.parse("90s") == {:ok, 90_000}
      assert Duration.parse("61s") == {:ok, 61_000}
      assert Duration.parse("1h90m") == {:ok, 9_000_000}
      assert Duration.parse("999999h") == {:ok, 999_999 * 3_600_000}
    end

    test "a zero in one position is fine as long as the total is positive" do
      assert Duration.parse("1h0m0s") == {:ok, 3_600_000}
      assert Duration.parse("0h5s") == {:ok, 5_000}
    end
  end

  describe "parse/1 — rejected input" do
    test "a bare number (no unit) is rejected — the ambiguity is the whole point" do
      assert {:error, reason} = Duration.parse("600")
      assert reason =~ "duration string"
    end

    test "an empty string is rejected (at least one segment required)" do
      assert {:error, _} = Duration.parse("")
    end

    test "a zero total is rejected as non-positive" do
      assert Duration.parse("0s") == {:error, "must be a positive duration"}
      assert Duration.parse("0h0m0s") == {:error, "must be a positive duration"}
    end

    test "segments out of order are rejected" do
      assert {:error, _} = Duration.parse("30s10m")
      assert {:error, _} = Duration.parse("1s2h")
      assert {:error, _} = Duration.parse("1m1h")
    end

    test "a repeated unit is rejected" do
      assert {:error, _} = Duration.parse("1m1m")
      assert {:error, _} = Duration.parse("1h1h")
    end

    test "an unknown unit, or a unit with no number, is rejected" do
      assert {:error, _} = Duration.parse("10d")
      assert {:error, _} = Duration.parse("1h2x")
      assert {:error, _} = Duration.parse("s")
      assert {:error, _} = Duration.parse("hms")
    end

    test "units are case-sensitive (lowercase only)" do
      assert {:error, _} = Duration.parse("10M")
      assert {:error, _} = Duration.parse("1H30M")
    end

    test "surrounding or internal whitespace is rejected" do
      assert {:error, _} = Duration.parse(" 10m")
      assert {:error, _} = Duration.parse("10m ")
      assert {:error, _} = Duration.parse("10m\n")
      assert {:error, _} = Duration.parse("1h 30m")
    end

    test "signed and fractional numbers are rejected" do
      assert {:error, _} = Duration.parse("-5m")
      assert {:error, _} = Duration.parse("+5m")
      assert {:error, _} = Duration.parse("1.5m")
    end

    test "a non-binary input is rejected without raising" do
      assert {:error, _} = Duration.parse(600)
      assert {:error, _} = Duration.parse(nil)
      assert {:error, _} = Duration.parse(:"10m")
    end
  end
end
