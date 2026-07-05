defmodule Mutare.Report.HarnessDiagnosticTest do
  use ExUnit.Case, async: true

  alias Mutare.{Result, Site}
  alias Mutare.Report.HarnessDiagnostic

  defp result(opts) do
    %Result{
      status: :harness_error,
      site: %Site{id: 7, file: "lib/a.ex", line: 12},
      exit_status: opts[:exit_status],
      output: opts[:output]
    }
  end

  test "summary includes the exit status and first useful output line" do
    diagnostic =
      HarnessDiagnostic.summary(
        result(
          exit_status: 99,
          output: "\nCompiling 1 file\n** (RuntimeError) could not start dependency\n"
        )
      )

    assert diagnostic == "exit 99; ** (RuntimeError) could not start dependency"
  end

  test "summary falls back cleanly without output or exit status" do
    assert HarnessDiagnostic.summary(result([])) == "exit unknown; no output captured"
  end

  test "summary names the known self-erasing boot crash instead of echoing useless output" do
    output = """
    Runtime terminating during boot ({badarg,[{io,put_chars,[standard_error,...]}]})
    """

    assert HarnessDiagnostic.summary(result(exit_status: 158, output: output)) ==
             "exit 158; sandbox node died during boot; likely startup contention"
  end

  test "line prefixes the diagnostic with file, line, and mutant id" do
    assert HarnessDiagnostic.line(result(exit_status: 99, output: "boom")) ==
             "lib/a.ex:12: mutant 7 — exit 99; boom"
  end
end
