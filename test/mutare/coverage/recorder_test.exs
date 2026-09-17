defmodule Mutare.Coverage.RecorderTest do
  use ExUnit.Case, async: true

  alias Mutare.Coverage.Recorder

  describe "record?/1 — gate-independent coverage payload recognition" do
    test "accepts inline and bound gates before and after literal-encoded reparse" do
      for namespace <- [nil, "lib/example.ex"],
          gate <- [Recorder.gate_ast(:mutare_active_4), {:mutare_tracking_3, [], nil}] do
        record = gated(gate, Recorder.hit_ast([1, 92, 1000], namespace))
        assert Recorder.record?(record)
        assert Recorder.record?(Sourceror.parse_string!(Sourceror.to_string(record)))
      end
    end

    test "rejects unrelated calls and malformed coverage payloads" do
      for {helper, args} <- [
            {:unrelated, [[1]]},
            {Recorder.fixture_module(), [42]},
            {Recorder.fixture_module(), [[]]},
            {Recorder.fixture_module(), [[0]]},
            {Recorder.fixture_module(), [[-1]]},
            {Recorder.fixture_module(), [[{:user_value, [], nil}]]},
            {Recorder.fixture_module(), ["", [1]]},
            {Recorder.fixture_module(), [:not_a_namespace, [1]]}
          ] do
        record =
          gated(Recorder.gate_ast(:mutare_active), {{:., [], [helper, :hit]}, [], args})

        refute Recorder.record?(record)
      end

      refute Recorder.record?({:and, [], [true, Recorder.hit_ast([1], nil)]})
      refute Recorder.record?(Recorder.hit_ast([1], nil))
      refute Recorder.record?(:ordinary_expression)
    end
  end

  describe "recorded_ids/1 — the payload's ids" do
    test "reads the local ids of a standalone or namespaced record, before and after reparse" do
      for namespace <- [nil, "lib/example.ex"] do
        record = Recorder.record_ast([3, 92, 1000], :mutare_active, namespace)
        assert Recorder.recorded_ids(record) == {:ok, [3, 92, 1000]}

        reparsed = Sourceror.parse_string!(Sourceror.to_string(record))
        assert Recorder.recorded_ids(reparsed) == {:ok, [3, 92, 1000]}
      end
    end

    test "is an error wherever record?/1 is false" do
      assert Recorder.recorded_ids(Recorder.hit_ast([1], nil)) == :error
      assert Recorder.recorded_ids(:ordinary_expression) == :error
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
               [:case, :->, :__block__, {:erlang, :"=:="}, {:persistent_term, :get}] ==
               [{Recorder.fixture_module(), :hit}]
    end

    @tag :coverage_tables
    test "reaches the helper only at baseline with tracking on" do
      # The value is the helper's `true` only when both short-circuits pass; `false` marks an
      # early exit. Under self-hosting, track_key/0 selects the private fixture flag.
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

    test "after_suite_ast/0 registers the dump under initialized probe mode" do
      ast = Recorder.after_suite_ast()
      rendered = Macro.to_string(ast)

      assert rendered =~ ":persistent_term.get(:mutare_probe, false)"
      assert rendered =~ "after_suite"
    end
  end

  defp gated(gate, hit) do
    quote do
      case unquote(gate) do
        true -> unquote(hit)
        _ -> false
      end
    end
  end
end
