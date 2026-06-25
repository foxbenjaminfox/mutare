defmodule Mutare.Poison.Hint do
  @moduledoc """
  Explain a metamutant compile failure that poison recovery couldn't fix.

  `Mutare.Poison` recovers from a compile-poisoning mutation by mapping the
  compiler's `file:line` to the offending mutant id and dropping it. That works
  whenever the error points *at* the spliced code. One class of failure defeats
  it: a **macro that requires a compile-time literal argument**
  (`Size.megabytes(5)`, `Bitwise`-style constant folders, custom DSL helpers).
  Mutare wraps the literal in a runtime selector `case`, the macro receives that
  `case` AST instead of a literal, and it raises while the compiler is *expanding*
  it. The compiler reports the **macro call site**, not the line of the spliced
  selector inside it — and those are different lines, so `Poison.ids/2` maps the
  error to nothing and the run aborts (the limitation documented in NOTES).

  The right fix is to tell Mutare to leave that macro's arguments alone by marking
  it `:skip` in `.mutare.exs` (the `:macros` option). This module turns the raw
  compile output into that advice: it pulls every macro named in an
  `expanding macro: Mod.fun/arity` stacktrace frame and renders a copy-pasteable
  `:skip` snippet, so the `Mix.Tasks.Mutare` error message says *how to fix it*
  rather than only dumping the compiler error.

  Pure (output string in, hint string out), so the diagnosis is unit-testable
  without a compile. Returns `nil` when no specific cause is recognised, leaving
  the generic compile-failure message to stand on its own.
  """

  # An `expanding macro: Mod.fun/arity` stacktrace frame, the signature of an
  # exception raised *during macro expansion* — a `FunctionClauseError` from a
  # literal-only clause, a `CompileError`/`ArgumentError` a macro raises itself.
  # `\S+` captures the whole qualified name (`Size.megabytes`, `MyApp.DSL.field`);
  # the trailing `/\d+` is the arity. Co-located with the message it feeds rather
  # than with the exit-code patterns in `Mutare.Sandbox.Command`: this is read only
  # for human remediation, never to form a verdict.
  @expanding_macro ~r{expanding macro:\s+(\S+)/(\d+)}

  # The header line of an exception/stacktrace (`** (FunctionClauseError) …`),
  # possibly indented. Each one starts a fresh expansion stack, so it re-arms the
  # innermost-frame capture in `innermost_macro_frames/1`.
  @exception_header ~r/^\s*\*\* \(/

  @doc """
  A remediation hint for the failed-compile `output`, or `nil` when none applies.

  Currently recognises the macro-expansion-needs-a-literal case (see the
  moduledoc); other failures return `nil`, so the caller falls back to showing the
  raw compiler error alone.
  """
  @spec for_compile_failure(String.t()) :: String.t() | nil
  def for_compile_failure(output) when is_binary(output) do
    case expanding_macros(output) do
      [] -> nil
      macros -> macro_skip_hint(macros)
    end
  end

  @doc """
  The distinct `{module_string, function_atom}` macros to advise skipping, drawn
  from the **innermost** `expanding macro:` frame of each stacktrace in `output`,
  in first-seen order. `[]` when none are present.

  Only the innermost frame is taken. A literal-only macro nested inside another
  (`if Size.megabytes(5)`) raises a *stack* of frames, printed innermost-first
  (`Size.megabytes/1`, then the enclosing `Kernel.if/2`). The outer frames are
  expansion *context*, not the culprit: only `Size.megabytes`'s argument was
  mutated. Advising `:skip` on an outer wrapper (`{Kernel, :if, :skip}` would stop
  Mutare descending into *every* `if`, hiding valid mutants) is wrong, so they are
  dropped. A new stacktrace (a fresh `** (Error)` header) re-arms the capture, so a
  multi-file failure still yields one culprit per error.

  Exposed (and pure) so the detection is testable apart from the message wording.

      iex> Mutare.Poison.Hint.expanding_macros("expanding macro: Size.megabytes/1\\n")
      [{"Size", :megabytes}]
  """
  @spec expanding_macros(String.t()) :: [{String.t(), atom()}]
  def expanding_macros(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> innermost_macro_frames()
    |> Enum.flat_map(&split_macro/1)
    |> Enum.uniq()
  end

  # The innermost `expanding macro:` frame of each stacktrace, in source order. The
  # compiler prints a macro-expansion stack innermost-first, so within one stacktrace
  # only the *first* frame is the macro whose literal argument Mutare mutated; the
  # rest are enclosing context. An `** (Error)` header re-arms capture for the next
  # stacktrace — so the result is one culprit per error, never an outer wrapper macro.
  defp innermost_macro_frames(lines) do
    {frames, _armed?} =
      Enum.reduce(lines, {[], true}, fn line, {frames, armed?} ->
        cond do
          Regex.match?(@exception_header, line) -> {frames, true}
          armed? -> capture_frame(line, frames)
          true -> {frames, armed?}
        end
      end)

    Enum.reverse(frames)
  end

  # Armed and still looking for this stacktrace's innermost frame: capture an
  # `expanding macro:` line (and disarm), else stay armed for a later line.
  defp capture_frame(line, frames) do
    case Regex.run(@expanding_macro, line) do
      [_match, qualified, _arity] -> {[qualified | frames], false}
      nil -> {frames, true}
    end
  end

  # Split `Mod.Sub.fun` into `{"Mod.Sub", :fun}`. A name with no `.` (no module
  # qualifier) can't be a macro frame we can advise on, so it's dropped — the
  # function part must be a plain function name (lowercase / `_`-led), never another
  # module segment, so a malformed capture yields `[]` rather than bad advice.
  defp split_macro(qualified) do
    case String.split(qualified, ".") do
      parts when length(parts) >= 2 ->
        {fun, module_parts} = List.pop_at(parts, -1)

        if function_name?(fun),
          do: [{Enum.join(module_parts, "."), String.to_atom(fun)}],
          else: []

      _ ->
        []
    end
  end

  # A bare function name starts lowercase or `_` (an uppercase lead is a module
  # segment — a sign the split went wrong, e.g. an operator macro we won't advise on).
  defp function_name?(<<c, _::binary>>) when c in ?a..?z or c == ?_, do: true
  defp function_name?(_), do: false

  defp macro_skip_hint(macros) do
    """
    A macro raised while the compiler was expanding it, so the metamutant could not
    be built — and Mutare could not isolate a single mutation to drop and retry
    (the compiler points at the macro call site, not the mutation spliced inside it).

    This usually means a mutation was inserted into an argument the macro requires to
    be a compile-time literal. The macro(s) that failed to expand:

    #{bullets(macros)}

    Tell Mutare to leave those macros' arguments unmutated by marking them `:skip`
    in .mutare.exs:

    #{snippet(macros)}

    (See `mix help mutare` for the `:macros` option.)\
    """
  end

  defp bullets(macros) do
    Enum.map_join(macros, "\n", fn {module, fun} -> "  * #{module}.#{fun}" end)
  end

  # A copy-pasteable `.mutare.exs` keyword list. One arity-agnostic 3-tuple per
  # macro (`{Module, :fun, :skip}`), so every arity of the macro is skipped.
  defp snippet(macros) do
    entries =
      Enum.map_join(macros, ",\n", fn {module, fun} ->
        "        {#{module}, #{inspect(fun)}, :skip}"
      end)

    """
        [
          macros: [
    #{entries}
          ]
        ]\
    """
  end
end
