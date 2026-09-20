defmodule Mutare.PipeMacroStageTest do
  # The evaluation contract for a piped stage Mutare mutates whole. A call is a function in
  # every respect its route does not address — unrouted, or routed for some other reason (to
  # hold an argument back, say) — so its piped value may be evaluated ahead of it, once, as a
  # function's first argument is. A callee that evaluates that operand late, conditionally, or
  # never says so with `:lazy_expression`, and is then handed the expression itself.
  # `with_active_mutant/2` sets the VM-wide selector, so these cannot run beside other tests.
  use ExUnit.Case, async: false
  import Mutare.Test

  alias Mutare.Test.{LazyDSL, LazyStageMutator}

  @source """
  defmodule Lazy do
    import Mutare.Test.LazyDSL

    def f(sink, on?), do: tick(sink) |> lazy(on?)

    defp tick(sink) do
      send(sink, :evaluated)
      :value
    end
  end
  """

  test "unrouted, the stage is treated as a function: its piped value is evaluated first" do
    {[module], [_site]} = compile_metamutant(@source, [LazyStageMutator])

    assert module.f(self(), false) == :skipped
    assert_received :evaluated
  end

  test "routed :expression, it still is: a route says nothing it does not say" do
    {[module], [_site]} =
      compile_metamutant(@source, [LazyStageMutator],
        call_routes: [{LazyDSL, :lazy, 2, [:expression, :expression]}]
      )

    assert module.f(self(), false) == :skipped
    assert_received :evaluated
  end

  test "routed :lazy_expression, the callee decides whether its piped operand is evaluated" do
    {[module], [site]} =
      compile_metamutant(@source, [LazyStageMutator],
        call_routes: [{LazyDSL, :lazy, 2, [:lazy_expression, :expression]}]
      )

    assert {site.original_code, site.mutated_code} == {"lazy(on?)", "lazy(true)"}

    assert module.f(self(), false) == :skipped
    refute_received :evaluated

    assert module.f(self(), true) == :value
    assert_received :evaluated

    assert with_active_mutant(site.id, fn -> module.f(self(), false) end) == :value
    assert_received :evaluated
  end

  test "a :lazy_expression argument is still mutated like any expression" do
    source = """
    defmodule LazyArgs do
      import Mutare.Test.LazyDSL
      def f(n, on?), do: (n + 1) |> lazy(on?)
    end
    """

    {[module], sites} =
      compile_metamutant(source, [:arithmetic],
        call_routes: [{LazyDSL, :lazy, 2, [:lazy_expression, :expression]}]
      )

    assert {3, 1} = observe_mutant(sites, {"n + 1", "n - 1"}, fn -> module.f(2, true) end)
  end
end
