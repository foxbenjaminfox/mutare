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

  Compiles are not serialized. Every module name a compile defines is claimed for the calling
  test module execution (`Mutare.Test.Compile.Names`), so two `async: true` modules that
  compile a same-named fixture fail deterministically instead of colliding when they happen
  to overlap: the top-level `defmodule` names are claimed before compiling, and every module
  the compile returned after it.

  Returns exactly what `Code.compile_string/2` returns (`[{module, binary}]`), so
  it is a drop-in replacement. When you *do* want to assert on a diagnostic, use
  `string_with_diagnostics/2` or capture `:stderr` directly — don't route through
  here.
  """

  alias Mutare.Test.Compile.Names

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
    claimed_compile(source, fn -> Code.compile_string(source, file) end)
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
    claimed_compile(source, fn ->
      try do
        {:ok, Code.compile_string(source, file)}
      rescue
        e -> {:error, e}
      end
    end)
  end

  @doc "The `message` of each diagnostic, in order — for `=~` assertions."
  def messages(diagnostics) when is_list(diagnostics), do: Enum.map(diagnostics, & &1.message)

  @doc """
  Run `compile`, a compile of `source` that bypasses this module (a test that needs the
  compiler's own stderr), under the same name claims as `string/2`.
  """
  def claiming(source, compile) when is_binary(source) and is_function(compile, 0) do
    Names.claim!(top_level_modules(source))
    result = compile.()
    Names.claim!(for {module, _binary} <- List.wrap(result), is_atom(module), do: module)
    result
  end

  defp claimed_compile(source, compile) when is_function(compile, 0) do
    Names.claim!(top_level_modules(source))
    {result, diagnostics} = Code.with_diagnostics(compile)

    compiled =
      case result do
        {:ok, modules} -> modules
        {:error, _exception} -> []
        modules -> modules
      end

    Names.claim!(for {module, _binary} <- compiled, do: module)
    {result, diagnostics}
  end

  # The names of the `defmodule`s at the top of `source`, read before compiling so a collision
  # is refused before the compiler meets it. A module nested in one of them is prefixed by it,
  # so these are enough; the modules a compile returns are claimed afterwards regardless. A
  # source that does not parse claims nothing here (its compile fails anyway).
  defp top_level_modules(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, {:__block__, _, forms}} -> Enum.flat_map(forms, &defined_module/1)
      {:ok, form} -> defined_module(form)
      {:error, _} -> []
    end
  end

  defp defined_module({:defmodule, _, [{:__aliases__, _, parts}, _body]})
       when is_list(parts),
       do: if(Enum.all?(parts, &is_atom/1), do: [Module.concat(parts)], else: [])

  defp defined_module(_form), do: []
end
