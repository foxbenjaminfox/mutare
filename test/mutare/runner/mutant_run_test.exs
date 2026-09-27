defmodule Mutare.Runner.MutantRunTest do
  use ExUnit.Case, async: true

  alias Mutare.{Options, Site}
  alias Mutare.Runner.{MutantRun, RunCtx}

  test "a selective result must contain every runnable mutant" do
    ctx = %RunCtx{
      options: Options.new([]),
      sandbox: "unused",
      selection: {:selective, %{}},
      cap: 1000,
      scopes: %{},
      partitions: :disabled,
      deadline: nil,
      on_start: fn _ -> :ok end,
      reporter: fn _ -> :ok end,
      on_phase: fn _ -> :ok end
    }

    site = %Site{id: 42, file: "lib/probe.ex", line: 3}

    assert_raise RuntimeError, ~r/selective coverage missed mutant #42/, fn ->
      MutantRun.run(ctx, site)
    end

    assert MutantRun.run(ctx, %{site | ignored: true}).status == :ignored
    assert MutantRun.run(ctx, %{site | poisoned: true}).status == :poisoned

    assert MutantRun.run(%{ctx | selection: {:selective, %{42 => :no_coverage}}}, site).status ==
             :no_coverage
  end
end
