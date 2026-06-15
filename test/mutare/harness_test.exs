defmodule Mutare.HarnessTest do
  @moduledoc """
  Infrastructure failures must not count as killed mutants.

  `Mutare.Sandbox.Command.timed_test/4` runs a real `mix test` and decodes its
  exit code against the contract `Mutare.Sandbox.Command` owns. These tests pin
  the three outcomes that share the "non-zero exit" space against actual `mix`
  subprocesses: a passing suite (survived), a *failing* suite (a clean kill, via
  the forced `--exit-status`), and a suite that can't even compile (a harness
  error — explicitly **not** a kill, which the old "non-zero ⇒ killed" rule got
  wrong).
  """
  use ExUnit.Case, async: false

  alias Mutare.Sandbox.Command
  alias Mutare.Sandbox.Command.Result
  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 120_000

  test "a passing suite is a pass (the mutation would survive)" do
    %{project: project} =
      Project.build(:harness_pass, %{
        "lib/m.ex" => "defmodule M do\n  def add(a, b), do: a + b\nend\n",
        "test/m_test.exs" => """
        defmodule MTest do
          use ExUnit.Case
          test "adds", do: assert M.add(1, 2) == 3
        end
        """
      })

    assert %Result{outcome: :passed, exit_status: 0, duration_ms: ms} =
             Command.timed_test(project, [], 0)

    assert is_integer(ms) and ms >= 0
  end

  test "a failing suite is a clean kill, not a harness error" do
    %{project: project} =
      Project.build(:harness_fail, %{
        "lib/m.ex" => "defmodule M do\n  def add(a, b), do: a + b\nend\n",
        "test/m_test.exs" => """
        defmodule MTest do
          use ExUnit.Case
          test "wrong on purpose", do: assert M.add(1, 2) == 99
        end
        """
      })

    # The forced `--exit-status` is what makes this a `:failed` (kill) rather than
    # an ambiguous non-zero exit indistinguishable from infrastructure failure.
    assert %Result{outcome: :failed, exit_status: status} = Command.timed_test(project, [], 0)
    assert status == Command.failure_exit()
  end

  test "a suite that can't compile is a harness error, NOT a kill" do
    %{project: project} =
      Project.build(:harness_broken, %{
        # Syntax error: never compiles, so `mix test` exits 1 before any verdict.
        "lib/m.ex" => "defmodule M do\n  def add(a, b), do: a +\nend\n",
        "test/m_test.exs" => """
        defmodule MTest do
          use ExUnit.Case
          test "unreachable", do: assert M.add(1, 2) == 3
        end
        """
      })

    assert %Result{outcome: :harness_error, exit_status: status} =
             Command.timed_test(project, [], 0)

    # Whatever mix exits with, it is neither success nor a clean test failure, so
    # it is never charged as a kill.
    refute status in [0, Command.failure_exit()]
  end
end
