defmodule Mutare.Transform.CaseClauseEmitTest do
  use ExUnit.Case, async: false

  alias Mutare.Coverage.Recorder
  alias Mutare.{Selector, Transform}

  defmodule CoverageSink do
    def hit(ids) do
      send(self(), {:covered, ids})
      true
    end
  end

  setup do
    previous = :persistent_term.get(Recorder.track_key(), false)
    Selector.put(Selector.baseline())
    :persistent_term.put(Recorder.track_key(), true)

    on_exit(fn ->
      Selector.put(Selector.baseline())
      :persistent_term.put(Recorder.track_key(), previous)
    end)

    :ok
  end

  test "the full hosted id list occurs once, independently of the clause count" do
    clauses = Enum.map_join(1..100, "\n", &"#{&1} -> :matched")
    source = "defmodule ManyCases do\ndef run(n) do\ncase n do\n#{clauses}\nend\nend\nend"

    {metamutant, sites, _} =
      Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.IntegerLiteral])

    assert length(sites) > 100
    helper = Recorder.fixture_module()

    {_ast, payloads} =
      metamutant
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [^helper, :hit]}, _, [ids]} = node, payloads -> {node, [ids | payloads]}
        node, payloads -> {node, payloads}
      end)

    assert payloads == [Enum.map(sites, & &1.id)]
  end

  test "records after one successful scrutinee evaluation and before the clause body" do
    {module, sites, _source} =
      compile_fixture(:Ordered, """
      def run(fun) do
        case value = fun.() do
          1 -> send(self(), :body)
          2 -> send(self(), :body)
        end
        value
      end
      """)

    assert apply(module, :run, [
             fn ->
               send(self(), :scrutinee)
               1
             end
           ]) == 1

    ids = Enum.map(sites, & &1.id)
    assert_receive first
    assert first == :scrutinee
    assert_receive second
    assert second == {:covered, ids}
    assert_receive third
    assert third == :body
    refute_receive {:covered, _}
    refute_receive :scrutinee
  end

  test "a raising scrutinee records no hosted ids; an unmatched subject records before raising" do
    {module, sites, _source} =
      compile_fixture(:Raises, """
      def run(fun) do
        case fun.() do
          1 -> :one
          2 -> :two
        end
      end
      """)

    assert_raise RuntimeError, "scrutinee", fn ->
      apply(module, :run, [fn -> raise "scrutinee" end])
    end

    refute_receive {:covered, _}

    error = assert_raise CaseClauseError, fn -> apply(module, :run, [fn -> :unmatched end]) end
    assert error.term == :unmatched
    ids = Enum.map(sites, & &1.id)
    assert_receive {:covered, ^ids}
    refute_receive {:covered, _}
  end

  test "keeps body coverage inside the selected original clause" do
    {module, sites, _source} =
      compile_fixture(:Body, """
      def run(n) do
        case n do
          1 -> 100
          2 -> 200
        end
      end
      """)

    assert apply(module, :run, [1]) == 100
    ids = fn code -> for site <- sites, site.original_code == code, do: site.id end
    hosted = ids.("1") ++ ids.("2")
    first_body = ids.("100")
    assert_receive {:covered, ^hosted}
    assert_receive {:covered, ^first_body}
    refute_receive {:covered, _}
  end

  test "salts the temp and preserves nested scrutinees and existing source bindings" do
    {module, _sites, source} =
      compile_fixture(
        :Bindings,
        """
        def run(mutare_case_subject, n) do
          result = case (case n do 1 -> :inner; _ -> :other end) do
            :inner -> :matched
            _ -> :fallback
          end
          {result, mutare_case_subject}
        end
        """,
        [Mutare.Mutators.IntegerLiteral, Mutare.Mutators.AtomLiteral]
      )

    assert source =~ "{mutare_active, mutare_case_subject_0} ->"
    assert apply(module, :run, [:preserved, 1]) == {:matched, :preserved}
  end

  test "the scrutinee temp stays invisible to source bindings and lexical macros" do
    {module, sites, _source} =
      compile_fixture(:ReflectedBindings, """
      defmacro case_temps do
        names = for {name, _} <- Macro.Env.vars(__CALLER__),
          String.starts_with?(Atom.to_string(name), "mutare_case_subject"), do: name
        Macro.escape(names)
      end

      def run(fun) do
        observed = case value = fun.() do
          1 -> {binding(), case_temps()}
          _ -> {binding(), case_temps()}
        end
        {observed, value, binding(), case_temps()}
      end
      """)

    for id <- [Selector.baseline() | Enum.map(sites, & &1.id)] do
      Selector.put(id)
      assert {{inside, []}, 1, after_case, []} = apply(module, :run, [fn -> 1 end])
      assert inside[:value] == 1
      assert after_case[:value] == 1

      for bindings <- [inside, after_case] do
        refute Enum.any?(bindings, fn {name, _} ->
                 String.starts_with?(Atom.to_string(name), "mutare_case_subject")
               end)
      end
    end
  end

  test "self-contained selector contexts read the active id before evaluating the scrutinee" do
    {module, sites, _source} =
      compile_fixture(:Rescue, """
      def run(fun) do
        raise "enter rescue"
      rescue
        _ ->
          case fun.() do
            1 -> :one
            2 -> :two
          end
      end
      """)

    retarget = Enum.find(sites, &(&1.original_code == "1" and &1.mutated_code == "2"))

    # Even if the callback changes the global setting, this case keeps the selector value
    # already read before its scrutinee. Mutare normally keeps that setting process-constant.
    assert apply(module, :run, [
             fn ->
               Selector.put(retarget.id)
               1
             end
           ]) == :one

    ids = Enum.map(sites, & &1.id)
    assert_receive {:covered, ^ids}
  end

  defp compile_fixture(name, body, mutators \\ [Mutare.Mutators.IntegerLiteral]) do
    module = Module.concat(__MODULE__, name)
    source = "defmodule #{inspect(module)} do\n#{body}\nend"
    {metamutant, sites, _} = Transform.transform_string_with_sites(source, mutators: mutators)

    # Keep the generated coverage gate, replacing only the sink with a process-local observer.
    observed =
      String.replace(
        metamutant,
        "#{inspect(Recorder.fixture_module())}.hit(",
        "#{inspect(CoverageSink)}.hit("
      )

    ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(observed) end)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    {module, sites, metamutant}
  end
end
