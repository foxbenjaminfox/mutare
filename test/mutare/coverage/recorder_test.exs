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
      forged_helper =
        Macro.prewalk(Recorder.record_ast([1], :mutare_active), fn
          {{:., _, [_helper, :hit]}, _, _} -> {{:., [], [:some_other_helper, :hit]}, [], [42]}
          node -> node
        end)

      assert Recorder.record_var(forged_helper) == :mutare_active
    end

    test "returns nil for a non-record node — a user `case` of the same shape without the track read" do
      # `x == 0` here is `Kernel.==`, not the explicit `:erlang` call the builder emits.
      not_a_record =
        quote do
          case x == 0 do
            true ->
              case foo() do
                true -> bar()
                _ -> false
              end

            _ ->
              false
          end
        end

      assert Recorder.record_var(not_a_record) == nil

      # A source-level `and`/`==` chain is not the generated record either.
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

    test "returns nil when the track read is present but the active-zero condition is malformed" do
      # The inner shape and the `:mutare_track` read match, but the outer condition is not
      # `<var>` against `0`: a call, then a comparison with a non-zero literal.
      key = Recorder.track_key()

      call_condition =
        quote do
          case f() do
            true ->
              case :persistent_term.get(unquote(key), false) do
                true -> :mutare_cov.hit([1])
                _ -> false
              end

            _ ->
              false
          end
        end

      nonzero_comparison =
        quote do
          case :erlang.==(mutare_active, 1) do
            true ->
              case :persistent_term.get(unquote(key), false) do
                true -> :mutare_cov.hit([1])
                _ -> false
              end

            _ ->
              false
          end
        end

      assert Recorder.record_var(call_condition) == nil
      assert Recorder.record_var(nonzero_comparison) == nil
    end
  end

  describe "record_ast/3 — the spliced expression" do
    test "is built from special forms and remote calls only, never a Kernel import" do
      # It is spliced into the target's modules, so nothing in it may resolve through the
      # target's imports: no `and`/`==`/`if`, and no `:erlang.andalso/2`, which Elixir
      # accepts only inside a guard.
      {_, locals} =
        Macro.prewalk(Recorder.record_ast([1, 2], :mutare_active, "lib/a.ex"), [], fn
          {{:., _, [mod, fun]}, _, _} = node, acc ->
            {node, [{mod, fun} | acc]}

          {name, _, args} = node, acc when is_atom(name) and name != :. and is_list(args) ->
            {node, [name | acc]}

          node, acc ->
            {node, acc}
        end)

      assert Enum.uniq(locals) --
               [:case, :->, :__block__, {:erlang, :==}, {:persistent_term, :get}] ==
               [{Recorder.fixture_module(), :hit}]
    end

    @tag :coverage_tables
    test "reaches the helper only at baseline with tracking on" do
      # The value is the helper's `true` only when both short-circuits pass; `false` marks an
      # early exit. The stand-in helper records nothing, but the tracking flag is shared
      # with the self-hosted coverage probe, so this test must be excluded from those runs.
      key = Recorder.track_key()
      on_exit(fn -> :persistent_term.erase(key) end)
      record = Recorder.record_ast([1, 2], :mutare_active)

      evaluate = fn active ->
        {value, _} = Code.eval_quoted(record, mutare_active: active)
        value
      end

      :persistent_term.erase(key)
      assert evaluate.(0) == false
      assert evaluate.(7) == false

      :persistent_term.put(key, true)
      assert evaluate.(0) == true
      assert evaluate.(7) == false
      assert evaluate.(:inactive) == false
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
