defmodule Mutare.PipeSyntaxTest do
  use ExUnit.Case, async: false
  import Mutare.Test

  @mutator Mutare.Test.PipeSyntaxMutator

  test "raw declarations and patterns reach each mutated macro as syntax" do
    source = """
    defmodule Syntax do
      import Mutare.Test.PipeSyntaxDSL
      def raw_pipe(n), do: (x in n) |> raw(x + 1)
      def pattern_pipe(n), do: {:ok, _} |> pattern(n)
      def binding_pipe(n), do: x |> binding(n)
      def escaping_binding(n) do
        x |> binding(n)
        x
      end
    end
    """

    {[module], sites} = compile_metamutant(source, [@mutator])
    assert length(sites) == 4
    assert module.raw_pipe(10) == 11
    assert module.pattern_pipe({:ok, 10})
    assert module.binding_pipe(10) == 10
    assert module.escaping_binding(10) == 10

    for site <- sites do
      with_active_mutant(site.id, fn ->
        assert module.raw_pipe(10) == if(site.original_code == "raw(x + 1)", do: 0, else: 11)

        assert module.pattern_pipe({:ok, 10}) ==
                 (site.original_code != "pattern(n)")

        # The escaping-binding path rehomes the candidate to the complete pipe;
        # its existing tuple export must continue to work beside ordinary delivery.
        if site.original_code == "binding(n)" do
          assert Enum.sort([module.binding_pipe(10), module.escaping_binding(10)]) == [0, 10]
        end
      end)
    end
  end

  test "a return-value selector can wrap a syntax-valued pipe's default" do
    source = """
    defmodule Tail do
      import Mutare.Test.PipeSyntaxDSL
      def f(n), do: (x in n) |> raw(x + 1)
    end
    """

    {[module], sites} = compile_metamutant(source, [@mutator, :return_value])
    assert module.f(10) == 11
    assert {11, 0} = observe_mutant(sites, {"raw(x + 1)", "raw(0)"}, fn -> module.f(10) end)
    assert Enum.any?(sites, &(&1.mutator == :return_value))
  end

  test "keyword, keyed and interpolated operands preserve syntax and their own mutants" do
    for {stage, left} <- [keyword: "[value: 5]", keyed: "[value: 5]", interpolated: "5"] do
      source = """
      defmodule Syntax do
        import Mutare.Test.PipeSyntaxDSL
        def f, do: #{left} |> #{stage}(5)
      end
      """

      {[module], sites} = compile_metamutant(source, [@mutator, :integer])
      assert module.f()
      assert Enum.count(sites, &(&1.mutator == :pipe_syntax)) == 1
      assert Enum.count(sites, &(&1.mutator == :integer)) == 3

      for site <- sites do
        refute with_active_mutant(site.id, fn -> module.f() end)
      end
    end
  end

  test "a pin keeps upstream selectors only in the default and evaluates once" do
    source = """
    defmodule Pins do
      import Mutare.Test.PipeSyntaxDSL
      def f do
        (^(Process.put(:pipe_input, :consumed) |> Enum.reverse())) |> interpolated([2, 1])
      end
    end
    """

    mutators = [@mutator, :call_removal]
    {[module], sites} = compile_metamutant(source, mutators)
    assert length(sites) == 2

    run = fn ->
      Process.put(:pipe_input, [1, 2])
      result = module.f()
      assert Process.delete(:pipe_input) == :consumed
      result
    end

    assert run.()

    for site <- sites do
      refute with_active_mutant(site.id, run)
    end

    emitted = metamutant_source(source, mutators)
    # The chain's selector and coverage each occur once, in the default branch.
    assert length(Regex.scan(~r/fn mutare_piped ->/, emitted)) == 1
  end

  describe "a chain of value-routed stages" do
    @chain """
    defmodule Chain do
      import Mutare.Test.PipeSyntaxDSL
      def f(n, sink), do: tick(n, sink) |> plus(1) |> plus(10) |> plus(100)
      def g(n), do: plus(plus(n, 1), 10)

      defp tick(n, sink) do
        send(sink, :evaluated)
        n
      end
    end
    """

    test "delivers each stage's mutant, evaluating the piped value once" do
      {[module], sites} = compile_metamutant(@chain, [@mutator])
      piped = Enum.filter(sites, &(&1.line == 3))
      assert Enum.map(piped, & &1.original_code) == ["plus(1)", "plus(10)", "plus(100)"]

      assert module.f(0, self()) == 111
      assert_received :evaluated
      refute_received :evaluated

      for {site, expected} <- Enum.zip(piped, [110, 101, 11]) do
        assert with_active_mutant(site.id, fn -> module.f(0, self()) end) == expected
        assert_received :evaluated
        refute_received :evaluated
      end
    end

    test "binds the piped value once per stage, and only for a stage written as a pipe" do
      emitted = metamutant_source(@chain, [@mutator])

      # `f`'s three piped stages each bind; `g`'s directly written calls never do — a macro may
      # evaluate a written argument late, or not at all.
      assert length(Regex.scan(~r/fn mutare_piped ->/, emitted)) == 3
      assert length(Regex.scan(~r/tick\(n, sink\)/, emitted)) == 2
    end

    test "falls back to plain delivery when a mutant does not keep the piped value" do
      # The tail stage also carries return-value constants, which replace the whole call: bound,
      # they would evaluate the upstream chain the constant was meant to stand in for.
      source = """
      defmodule Tail do
        import Mutare.Test.PipeSyntaxDSL
        def f(n), do: n |> plus(1) |> plus(10)
      end
      """

      {[module], sites} = compile_metamutant(source, [@mutator, :return_value])
      assert module.f(0) == 11
      assert Enum.any?(sites, &(&1.mutator == :return_value))

      emitted = metamutant_source(source, [@mutator, :return_value])
      assert length(Regex.scan(~r/fn mutare_piped ->/, emitted)) == 1

      assert {11, 10} = observe_mutant(sites, {"plus(1)", "plus(0)"}, fn -> module.f(0) end)
      assert {11, 1} = observe_mutant(sites, {"plus(10)", "plus(0)"}, fn -> module.f(0) end)
    end
  end

  test "an interpolated left operand compiles when the stage has no mutant" do
    source = """
    defmodule Pins do
      import Mutare.Test.PipeSyntaxDSL
      def f, do: 5 |> interpolated(5)
    end
    """

    {[module], sites} =
      compile_metamutant(source, [:integer], extensions: [Mutare.Test.PipeSyntaxDSL])

    assert length(sites) == 3
    assert module.f()

    for site <- sites, do: refute(with_active_mutant(site.id, fn -> module.f() end))
  end
end

defmodule Mutare.PipeSyntaxPropertyTest do
  use ExUnit.Case, async: true
  use PropCheck

  @moduletag :property

  property "syntax-valued prefixes keep rendered growth linear", numtests: 30 do
    forall [depth, shape] <- [integer(2, 16), elements([:raw, :pattern, :interpolated, :keyword])] do
      short = transform(depth, shape)
      long = transform(depth * 2, shape)
      # Pattern pins currently stay in pattern context; interpolation and keyword values
      # really do contain emitted upstream selectors, which must appear only once.
      assert length(short.sites) == if(shape == :pattern, do: 1, else: depth + 1)
      assert length(long.sites) == if(shape == :pattern, do: 1, else: depth * 2 + 1)
      assert byte_size(long.metamutant) < 3 * byte_size(short.metamutant)
      Mutare.Test.Metamutant.assert_compiles(long.metamutant)
      true
    end
  end

  property "a chain of value-routed stages keeps rendered growth linear", numtests: 10 do
    forall depth <- integer(2, 16) do
      short = routed_chain(depth)
      long = routed_chain(depth * 2)
      assert length(short.sites) == depth
      assert length(long.sites) == depth * 2
      assert byte_size(long.metamutant) < 3 * byte_size(short.metamutant)
      Mutare.Test.Metamutant.assert_compiles(long.metamutant)
      true
    end
  end

  defp routed_chain(depth) do
    chain = Enum.map_join(1..depth, "", fn i -> " |> plus(#{i})" end)

    Mutare.Transform.transform_string_with_sites(
      """
      defmodule RoutedChain do
        import Mutare.Test.PipeSyntaxDSL
        def f(n) do
          total = n#{chain}
          total
        end
      end
      """,
      file: "routed_chain.ex",
      mutators: [Mutare.Test.PipeSyntaxMutator]
    )
  end

  defp transform(depth, shape) do
    chain = Enum.map_join(1..depth, "", fn _ -> " |> Enum.reverse()" end)

    body =
      case shape do
        :raw -> "(x in xs) |> raw(x)#{chain}"
        :pattern -> "{:ok, ^(xs#{chain})} |> pattern(value)"
        :interpolated -> "(^(xs#{chain})) |> interpolated(value)"
        :keyword -> "[value: xs#{chain}] |> keyword(value)"
      end

    Mutare.Transform.transform_string_with_sites(
      """
      defmodule Chain do
        import Mutare.Test.PipeSyntaxDSL
        def f(xs, value), do: #{body}
      end
      """,
      mutators: [Mutare.Test.PipeSyntaxMutator, :call_removal],
      verify_invariants: true
    )
  end
end
