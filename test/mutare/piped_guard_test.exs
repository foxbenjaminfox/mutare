defmodule Mutare.PipedGuardTest do
  @moduledoc """
  A routed call piped inside a **guard**. `Mutare.Transform.Tag`'s guard walk reads code as
  Elixir just as `Analyze` does, so it owes a piped routed stage the same reading — the direct
  call `Mutare.Transform.WrittenPipe.direct/1` makes of it. Read as written, the stage's
  treatments would land one argument late (`Mutare.Transform.Meta.routing/1` raises instead).
  """
  # `SourcePatch.assert_patches/4` selects mutants process-globally.
  use ExUnit.Case, async: false

  # The guard walk (`Mutare.Transform.Tag`) reads code as Elixir just as `Analyze` does, so it
  # owes the stage the same reading: `rem/2`'s position 0 is `n`, not the written `2`.
  @routes [{Kernel, :rem, 2, [:raw, :expression]}]

  defp guard_source(guard) do
    """
    defmodule PipedGuardFixture do
      def parity(n) when #{guard}, do: :even
      def parity(_n), do: :odd
    end
    """
  end

  defp guard_mutants(guard) do
    %{sites: sites} =
      Mutare.Transform.transform_string_with_sites(guard_source(guard),
        file: "piped_guard.ex",
        mutators: [:integer, :arithmetic],
        call_routes: @routes
      )

    sites |> Enum.map(&{&1.mutator, &1.mutated_code}) |> Enum.sort()
  end

  test "is routed by the direct call's positions" do
    piped = guard_mutants("n |> rem(2) == 0")

    assert {:integer, "3"} in piped
    assert {:arithmetic, "n |> div(2)"} in piped

    assert Enum.map(piped, &elem(&1, 0)) ==
             Enum.map(guard_mutants("rem(n, 2) == 0"), &elem(&1, 0))
  end

  test "is delivered, and every site patches the source it was written in" do
    Mutare.Test.SourcePatch.assert_patches(
      guard_source("n |> rem(2) == 0"),
      [:integer, :arithmetic],
      [parity: [4], parity: [3], parity: [0]],
      call_routes: @routes
    )
  end
end
