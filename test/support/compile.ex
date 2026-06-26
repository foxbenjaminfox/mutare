defmodule Mutare.Test.Compile do
  @moduledoc """
  Compile a generated metamutant string while swallowing the compiler's
  *expected* warnings.

  A metamutant is deliberately warn-y build output — gated mutant clauses leave
  unused head variables, fixtures redefine the same module name across cases, and
  some mutant clauses are unreachable behind the dispatcher guard. Those
  diagnostics carry no signal for a test that only cares *whether the thing
  compiles*, and they scatter through (otherwise green) test output.

  This wraps `Code.compile_string/2` in `Code.with_diagnostics/2`, which captures
  compiler diagnostics *per-process* instead of printing them — so unlike
  `ExUnit.CaptureIO.capture_io(:stderr, …)` it never touches the global
  `:standard_error` device and is safe under `async: true`.

  Returns exactly what `Code.compile_string/2` returns (`[{module, binary}]`), so
  it is a drop-in replacement. When you *do* want to assert on a diagnostic, use
  `string_with_diagnostics/2` or capture `:stderr` directly — don't route through
  here.
  """

  @doc """
  Compile `source`, suppressing (expected) compiler warnings. Drop-in for
  `Code.compile_string/2`.
  """
  def string(source, file \\ "nofile") do
    {modules, _diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(source, file) end)

    modules
  end

  @doc """
  Like `string/2`, but also returns the captured diagnostics for the rare test
  that wants to inspect them without going through `:stderr`.
  """
  def string_with_diagnostics(source, file \\ "nofile") do
    Code.with_diagnostics(fn -> Code.compile_string(source, file) end)
  end
end
