defmodule Mutare.Coverage.RecorderTest do
  use ExUnit.Case, async: true

  alias Mutare.AST
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
      {:ok, [conj, _hit]} = AST.erlang_call_args(record, :andalso)

      forged_helper =
        AST.erlang_call(:andalso, [conj, {{:., [], [:some_other_helper, :hit]}, [], [42]}])

      assert Recorder.record_var(forged_helper) == :mutare_active
    end

    test "returns nil for a non-record node — a user `x == 0 and …` without the track read" do
      not_a_record =
        AST.erlang_call(:andalso, [
          AST.erlang_call(:andalso, [AST.erlang_call(:==, [{:x, [], nil}, 0]), {:foo, [], []}]),
          {:bar, [], []}
        ])

      assert Recorder.record_var(not_a_record) == nil

      # A source-level `and`/`==` is not the generated record: the builder emits explicit
      # `:erlang` calls precisely so a target's own operators can never be mistaken for one.
      assert Recorder.record_var(
               {:and, [],
                [
                  {:and, [],
                   [
                     {:==, [], [{:mutare_active, [], nil}, 0]},
                     {{:., [], [:persistent_term, :get]}, [], [Recorder.track_key(), false]}
                   ]},
                  {{:., [], [:mutare_cov, :hit]}, [], [[1]]}
                ]}
             ) == nil

      assert Recorder.record_var({:x, [], nil}) == nil
      assert Recorder.record_var(:not_even_a_tuple) == nil
    end

    test "returns nil when the track read is present but the active-zero conjunct is malformed" do
      # The outer shape and the `:mutare_track` read match, but the left conjunct is not the
      # `<var> == 0` gate — so `active_zero_var/1` falls to its `nil` clause.
      track_read = {{:., [], [:persistent_term, :get]}, [], [Recorder.track_key(), false]}
      hit = {{:., [], [:mutare_cov, :hit]}, [], [[1]]}

      malformed =
        AST.erlang_call(:andalso, [
          AST.erlang_call(:andalso, [{:not_a_gate, [], []}, track_read]),
          hit
        ])

      assert Recorder.record_var(malformed) == nil
    end
  end

  describe "generated contract surface" do
    test "catch_all_pattern/0 builds a bare-variable pattern with the canonical dispatch name" do
      assert Recorder.catch_all_pattern() == {Recorder.var_name(), [], nil}
    end

    test "helper_source/0 is the dependency-free helper module source" do
      source = Recorder.helper_source()

      assert is_binary(source)
      assert source =~ "defmodule"
      assert source =~ "def hit"
      assert source =~ "def dump"
    end

    test "after_suite_ast/0 builds the env-gated after_suite registration" do
      ast = Recorder.after_suite_ast()
      rendered = Macro.to_string(ast)

      assert rendered =~ Recorder.env_var()
      assert rendered =~ "after_suite"
    end
  end
end
