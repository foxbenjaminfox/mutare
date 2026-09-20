defmodule Mutare.PipeSpellingPropertyTest do
  # `left |> stage(args)` is sugar for `stage(left, args)`, and nothing Mutare does may depend on
  # which one the user wrote. For a generated chain of stages — routed and eager, routed and lazy,
  # unrouted — every spelling (each stage piped or direct, independently) must yield the same
  # mutants, the same behaviour under each, and the same evaluations of the chain's head.
  use ExUnit.Case, async: false
  use PropCheck

  import Mutare.Test

  @moduletag :property

  # `:numeric` and `:operand_swap` key on a call's arity and move its first operand: the
  # families that once read a pipe stage one argument short, and answered differently for it.
  @mutators [
    Mutare.Test.PipeSyntaxMutator,
    :integer,
    :arithmetic,
    :return_value,
    :numeric,
    :operand_swap
  ]

  # Routes that say of a function only what is already true of it.
  @idle_routes [
    {Kernel, :max, 2, [:expression, :expression]},
    {Kernel, :div, 2, [:expression, :expression]}
  ]
  @inputs [0, 3, -2]

  property "a chain means the same however its stages are spelled", numtests: 150 do
    forall {stages, spelling_a, spelling_b} <- chain() do
      a = observe(stages, spelling_a)
      b = observe(stages, spelling_b)

      (a == b)
      |> when_fail(
        IO.puts("""
        #{source(stages, spelling_a)}
        #{inspect(a, pretty: true)}
        ---
        #{source(stages, spelling_b)}
        #{inspect(b, pretty: true)}
        """)
      )
    end
  end

  # A route addresses what it names and nothing else: one that declares a function's arguments
  # the values they already are changes no mutant, however the call is spelled.
  property "a route that says nothing new changes nothing", numtests: 100 do
    forall {stages, spelling, _other} <- chain() do
      unrouted = observe(stages, spelling)
      routed = observe(stages, spelling, call_routes: @idle_routes)

      (unrouted == routed)
      |> when_fail(
        IO.puts("""
        #{source(stages, spelling)}
        #{inspect(unrouted, pretty: true)}
        --- with #{inspect(@idle_routes)}
        #{inspect(routed, pretty: true)}
        """)
      )
    end
  end

  defp chain do
    let stages <- non_empty(resize(4, list(stage()))) do
      spelling = vector(length(stages), elements([:piped, :direct]))
      {stages, spelling, spelling}
    end
  end

  # Never 0: the fixture mutator's one mutation rewrites a stage's last argument *to* 0.
  defp stage, do: {elements([:plus, :lazy_plus, :max, :div]), elements([-2, -1, 1, 2, 3, 5])}

  # What a spelling amounts to: per mutator, the multiset of "what this mutant does" — its
  # results and head-evaluation counts over the inputs — beside the baseline's. Ids and source
  # positions differ between spellings by design; behaviour may not.
  defp observe(stages, spelling, opts \\ []) do
    {[module], sites} = compile_metamutant(source(stages, spelling), @mutators, opts)

    mutants =
      sites
      |> Enum.map(fn site ->
        {site.mutator, with_active_mutant(site.id, fn -> run(module) end)}
      end)
      |> Enum.sort()

    %{baseline: run(module), mutants: mutants}
  end

  defp run(module) do
    for input <- @inputs do
      result =
        try do
          module.f(input, self())
        rescue
          exception -> {:raised, exception.__struct__}
        end

      {result, drain()}
    end
  end

  defp drain(count \\ 0) do
    receive do
      :evaluated -> drain(count + 1)
    after
      0 -> count
    end
  end

  defp source(stages, spelling) do
    """
    defmodule Spelled do
      import Mutare.Test.PipeSyntaxDSL

      def f(n, sink) do
        result = #{expression(stages, spelling)}
        result
      end

      defp tick(n, sink) do
        send(sink, :evaluated)
        n
      end
    end
    """
  end

  defp expression(stages, spelling) do
    stages
    |> Enum.zip(spelling)
    |> Enum.reduce("tick(n, sink)", fn
      {{name, k}, :piped}, acc -> "(#{acc} |> #{name}(#{k}))"
      {{name, k}, :direct}, acc -> "#{name}(#{acc}, #{k})"
    end)
  end
end
