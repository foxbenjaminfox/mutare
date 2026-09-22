defmodule Mutare.Options.ParallelismTest do
  # Pure arithmetic over generated integers — fast, so not tagged `:property`.
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.Options.Parallelism

  doctest Parallelism

  defp given(generator), do: oneof([nil, generator])
  defp schedulers, do: oneof([:all, pos_integer()])

  property "what the user gave is never changed" do
    forall {workers, scheds, budget} <- {given(pos_integer()), given(schedulers()), pos_integer()} do
      {resolved_workers, resolved_scheds} = Parallelism.resolve(workers, scheds, budget)

      (workers == nil or resolved_workers == workers) and
        (scheds == nil or resolved_scheds == scheds)
    end
  end

  property "a resolved pair is concrete, and resolving it again changes nothing" do
    forall {workers, scheds, budget} <- {given(pos_integer()), given(schedulers()), pos_integer()} do
      {resolved_workers, resolved_scheds} =
        resolved = Parallelism.resolve(workers, scheds, budget)

      is_integer(resolved_workers) and resolved_workers > 0 and
        (resolved_scheds == :all or (is_integer(resolved_scheds) and resolved_scheds > 0)) and
        Parallelism.resolve(resolved_workers, resolved_scheds, budget) == resolved
    end
  end

  # The point of the feature. The given side may itself exceed the budget (more workers than
  # cores); then the derived side bottoms out at one rather than the product fitting. Derived
  # workers also stop at the default's clamp, so a lone `:schedulers` may leave cores spare.
  property "a derived side keeps the product within the budget, and wastes less than one share" do
    forall {given_side, budget, which} <-
             {pos_integer(), pos_integer(), oneof([:workers, :scheds])} do
      {workers, scheds} =
        case which do
          :workers -> Parallelism.resolve(given_side, nil, budget)
          :scheds -> Parallelism.resolve(nil, given_side, budget)
        end

      derived = if which == :workers, do: scheds, else: workers

      if given_side > budget do
        derived == 1
      else
        workers * scheds <= budget and
          (workers * scheds > budget - given_side or (which == :scheds and workers == 4)) and
          Parallelism.oversubscription(workers, scheds, budget) <= 1.0
      end
    end
  end

  property "with nothing given, workers stay a small constant and the pair fits the budget" do
    forall budget <- pos_integer() do
      {workers, scheds} = Parallelism.resolve(nil, nil, budget)
      workers in 1..4 and workers * scheds <= budget
    end
  end

  test "a lone :schedulers keeps the workers clamp" do
    assert Parallelism.resolve(nil, 2, 64) == {4, 2}
    assert Parallelism.resolve(nil, 8, 64) == {4, 8}
    assert Parallelism.resolve(nil, 16, 64) == {4, 16}
    assert Parallelism.resolve(nil, 32, 64) == {2, 32}
    assert Parallelism.resolve(nil, 1, 3) == {3, 1}
  end

  test "the defaults on common machines" do
    assert Parallelism.resolve(nil, nil, 1) == {1, 1}
    assert Parallelism.resolve(nil, nil, 2) == {1, 2}
    assert Parallelism.resolve(nil, nil, 6) == {3, 2}
    assert Parallelism.resolve(nil, nil, 8) == {4, 2}
    assert Parallelism.resolve(nil, nil, 32) == {4, 8}
  end

  test "untrimmed runs oversubscribe by their count; more workers than cores, by the excess" do
    assert Parallelism.oversubscription(8, :all, 16) == 8.0
    assert Parallelism.oversubscription(32, 1, 16) == 2.0
  end
end
