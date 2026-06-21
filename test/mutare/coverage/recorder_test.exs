defmodule Mutare.Coverage.RecorderTest do
  use ExUnit.Case, async: true

  alias Mutare.Coverage.Recorder

  describe "record_var/1 — recovering the dispatch variable from a coverage record" do
    test "round-trips the variable name `record_ast/2` builds with" do
      assert Recorder.record_var(Recorder.record_ast([1, 2, 3])) == Recorder.var_name()
      assert Recorder.record_var(Recorder.record_ast([7], :mutare_active_0)) == :mutare_active_0
    end

    test "sees through a literal-encoding re-parse's `:__block__` wrapping" do
      # `Mutare.Manifest` re-parses with a `:literal_encoder`, so the `0` / track-key
      # literals arrive `{:__block__, _, [literal]}`-wrapped; recognition must survive it.
      reparsed =
        Recorder.record_ast([1], :mutare_active_4)
        |> Sourceror.to_string()
        |> Code.string_to_quoted!(
          columns: true,
          token_metadata: true,
          literal_encoder: fn literal, meta -> {:ok, {:__block__, meta, [literal]}} end
        )

      assert Recorder.record_var(reparsed) == :mutare_active_4
    end

    test "ignores the helper-call arm, so a self-hosting helper-module override is irrelevant" do
      record = Recorder.record_ast([1], :mutare_active)
      {:and, m, [conj, _hit]} = record
      forged_helper = {:and, m, [conj, {{:., [], [:some_other_helper, :hit]}, [], [42]}]}

      assert Recorder.record_var(forged_helper) == :mutare_active
    end

    test "returns nil for a non-record node — a user `x == 0 and …` without the track read" do
      not_a_record =
        {:and, [],
         [
           {:and, [], [{:==, [], [{:x, [], nil}, 0]}, {:foo, [], []}]},
           {:bar, [], []}
         ]}

      assert Recorder.record_var(not_a_record) == nil
      assert Recorder.record_var({:x, [], nil}) == nil
      assert Recorder.record_var(:not_even_a_tuple) == nil
    end
  end
end
