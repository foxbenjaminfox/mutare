defmodule Mutare.PipeStageLineTest do
  # A mutant of a pipe stage is keyed at the stage's line — the line a `# mutare:ignore` over
  # the stage names, and the one `--line` selects (`schema_test.exs`) — even when the mutant moves the piped value
  # and so has to be reported, and patched, over the whole pipe.
  use ExUnit.Case, async: true

  @source """
  defmodule Chain do
    def run(xs, ys) do
      xs
      |> Enum.map(&(&1 * 2))
      |> Enum.uniq()
      |> Kernel.--(ys)
    end
  end
  """

  defp sites(source, opts \\ []) do
    Mutare.Transform.transform_string_with_sites(
      source,
      [mutators: [Mutare.Mutators.CallRemoval, Mutare.Mutators.OperandSwap]] ++ opts
    ).sites
  end

  test "a removed or transposed stage is located at the stage, and ranged over the pipe" do
    assert [removal, swap] = sites(@source)

    assert {removal.mutator, removal.line, removal.range.start[:line]} == {:call_removal, 5, 3}
    assert removal.mutated_code == "xs\n|> Enum.map(&(&1 * 2))"

    assert {swap.mutator, swap.line, swap.range.start[:line]} == {:operand_swap, 6, 3}
  end

  test "a directive over the stage's line suppresses it" do
    source =
      String.replace(
        @source,
        "    |> Enum.uniq()\n",
        "    # mutare:ignore[call_removal] order is unobservable here\n    |> Enum.uniq()\n"
      )

    assert [%{mutator: :call_removal, ignored: true}, %{mutator: :operand_swap, ignored: false}] =
             sites(source)
  end
end
