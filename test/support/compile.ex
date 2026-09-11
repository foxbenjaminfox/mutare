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

  The compile itself is serialized suite-wide behind a global lock (see
  `locked_compile/2`): two `async: true` test modules compiling a same-named
  throwaway fixture (`defmodule M`, …) concurrently would otherwise abort the
  parallel checker. The lock only spans the brief compile call.

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
    {modules, _diagnostics} = string_with_diagnostics(source, file)
    modules
  end

  @doc """
  Like `string/2`, but also returns the captured diagnostics for the rare test
  that wants to inspect them without going through `:stderr`.
  """
  def string_with_diagnostics(source, file \\ "nofile") do
    locked_compile(fn -> Code.compile_string(source, file) end)
  end

  @doc """
  Compile `source` without letting a compile failure escape: returns
  `{{:ok, modules} | {:error, exception}, diagnostics}`.

  A `CompileError` raised by `Code.compile_string/2` no longer carries the
  detail ("errors have been logged"); the detail is the `:error`-severity
  diagnostic, which this keeps. For tests that expect the compile to *fail*
  and want to read why, or that turn a failure into a readable flunk.
  """
  def string_result(source, file \\ "nofile") do
    locked_compile(fn ->
      try do
        {:ok, Code.compile_string(source, file)}
      rescue
        e -> {:error, e}
      end
    end)
  end

  @doc "The `message` of each diagnostic, in order — for `=~` assertions."
  def messages(diagnostics) when is_list(diagnostics), do: Enum.map(diagnostics, & &1.message)

  # `Code.compile_string/2` registers the module name in the global parallel-checker
  # table, so two *different* async test modules compiling a same-named throwaway
  # fixture (`defmodule M`, …) at the same instant make the checker abort with
  # "cannot compile module M". The throwaway names collide freely across files, so we
  # serialize the compile step suite-wide with a global lock — letting the (split)
  # transform test files stay `async: true` without renaming every fixture. The lock is
  # node-local (one node) and only spans the brief compile call, so concurrency elsewhere
  # is unaffected; `:global.trans/2` releases it even if the compile raises.
  defp locked_compile(compile) when is_function(compile, 0) do
    :global.trans({__MODULE__, self()}, fn -> Code.with_diagnostics(compile) end)
  end
end
