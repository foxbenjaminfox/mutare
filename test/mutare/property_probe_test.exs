defmodule Mutare.PropertyProbeTest do
  @moduledoc """
  Regression cover for `Mutare.PropertyProbe`'s regex normalisation.

  Starting on Erlang/OTP 28 a `~r/…/` literal compiles to a PCRE2 NIF resource — a
  per-compilation-unit `#Reference` carried in the `Regex` struct's `re_pattern` — so two
  separately compiled but textually identical regexes are never `==`, even with equal
  `source`/`opts`. That made `transform_baseline_property_test` (which compares the original and
  the metamutant as two **separate** compiles) spuriously diverge whenever the generator emitted a
  runtime regex — seed-gated, so it read as flaky on OTP 28 and passed everywhere else. `probe/1`
  now reduces every regex to its stable `{:"$regex", source, opts}` identity.

  These assert the normalised *shape* directly, so they pin the fix on **every** OTP version
  rather than only reproducing the OTP-28 symptom — a revert fails here on OTP 26 too.
  See NOTES "OTP 28 regex `re_pattern` is a per-compile reference".
  """
  # Compiles the shared `Prop` fixture name and purges it, exactly like the property tests it
  # backs; must not overlap them (or each other) — keep serial.
  use ExUnit.Case, async: false

  alias Mutare.PropertyProbe

  describe "normalize/1" do
    test "reduces a regex to its {source, opts} identity" do
      assert PropertyProbe.normalize(~r/ab/) == {:"$regex", "ab", []}
      assert PropertyProbe.normalize(~r/a.c/i) == {:"$regex", "a.c", [:caseless]}
    end

    test "deep-walks lists, tuples, and plain maps" do
      assert PropertyProbe.normalize([~r/ab/, 1]) == [{:"$regex", "ab", []}, 1]
      assert PropertyProbe.normalize({~r/ab/, :x}) == {{:"$regex", "ab", []}, :x}

      assert PropertyProbe.normalize(%{k: ~r/ab/}) == %{k: {:"$regex", "ab", []}}
      # A regex as a map *key* is normalised too (Map.new over both sides).
      assert PropertyProbe.normalize(%{~r/ab/ => 1}) == %{{:"$regex", "ab", []} => 1}

      # Nested arbitrarily deep.
      assert PropertyProbe.normalize([{:ok, [~r/ab/]}]) == [{:ok, [{:"$regex", "ab", []}]}]
    end

    test "leaves other structs and scalars untouched" do
      # The generator's other sigils (~D/~T/~N/~U) are value-comparable structs — must pass through.
      assert PropertyProbe.normalize(~D[2020-01-15]) == ~D[2020-01-15]
      assert PropertyProbe.normalize(~T[12:30:00]) == ~T[12:30:00]
      assert PropertyProbe.normalize(42) == 42
      assert PropertyProbe.normalize(:ok) == :ok
      assert PropertyProbe.normalize("ab") == "ab"
      assert PropertyProbe.normalize(nil) == nil
    end
  end

  describe "probe/1 (end to end)" do
    test "a returned regex is normalised — no Regex struct leaks into the outcome" do
      {:ok, outcome} =
        PropertyProbe.with_compiled(regex_module("ab"), fn ->
          PropertyProbe.probe({:f, [1]})
        end)

      assert outcome == {:value, {:"$regex", "ab", []}}
    end

    test "a regex nested in a returned collection is normalised end to end" do
      {:ok, outcome} =
        PropertyProbe.with_compiled("defmodule Prop do def f(_a), do: [~r/ab/, :tail] end", fn ->
          PropertyProbe.probe({:f, [1]})
        end)

      assert outcome == {:value, [{:"$regex", "ab", []}, :tail]}
    end

    test "two SEPARATE compiles of the same regex probe equal (the OTP-28 divergence the fix prevents)" do
      a = probe_separate_compile(regex_module("ab"))
      b = probe_separate_compile(regex_module("ab"))

      # Without normalisation this holds on OTP 27- (binary re_pattern) but fails on OTP 28
      # (each compile mints a fresh #Reference). With normalisation it holds everywhere.
      assert a == b
    end

    test "different regexes still probe unequal (normalisation must not mask real kills)" do
      a = probe_separate_compile(regex_module("ab"))
      b = probe_separate_compile(regex_module("cd"))

      assert a != b
    end

    test "raise / non-regex tagging is unaffected by normalisation" do
      {:ok, raised} =
        PropertyProbe.with_compiled("defmodule Prop do def f(_a), do: raise(\"boom\") end", fn ->
          PropertyProbe.probe({:f, [1]})
        end)

      assert raised == {:raised, RuntimeError}

      {:ok, plain} =
        PropertyProbe.with_compiled("defmodule Prop do def f(a), do: a end", fn ->
          PropertyProbe.probe({:f, [:value]})
        end)

      assert plain == {:value, :value}
    end
  end

  # A `Prop` fixture whose only function returns the given regex source.
  defp regex_module(source), do: "defmodule Prop do def f(_a), do: ~r/#{source}/ end"

  # Compile `source` as its own unit, probe `f/1` at the loaded module, then purge — so each call
  # is a distinct compilation unit (the condition that makes OTP 28's per-compile #Reference bite).
  defp probe_separate_compile(source) do
    {:ok, outcome} = PropertyProbe.with_compiled(source, fn -> PropertyProbe.probe({:f, [1]}) end)
    outcome
  end
end
