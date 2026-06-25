defmodule Mutare.Poison.Hint do
  @moduledoc """
  Turns one unrecoverable compile failure into advice the user can act on.

  Almost every compile-poisoning mutation is recovered automatically — Mutare
  finds the offending mutant, drops it, and rebuilds. One case can't be: a macro
  that requires a **compile-time literal argument** (`Size.megabytes(5)` and the
  like). Mutating the literal turns it into runtime code, the macro rejects it and
  raises while the compiler is expanding it, and because the compiler blames the
  macro *call* rather than the mutation inside it, Mutare can't tell which single
  mutant to drop. The whole run aborts.

  The way out is to leave that macro's arguments unmutated by marking it `:skip`
  in `.mutare.exs` (the `:macros` option). This module recognises the situation
  from the failed compile's output, identifies the macro(s) at fault, and produces
  that advice — including a copy-pasteable snippet — so the error the user sees
  explains how to get unblocked instead of just echoing the raw compiler error.

  Returns `nil` for any other compile failure, where the raw error stands on its
  own.
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
  A copy-pasteable remediation hint for the failed-compile `output`, or `nil`.

  Recognises the one poison case Mutare can't recover on its own — a macro that
  needs a compile-time literal argument — and returns advice on how to skip it.
  Any other failure returns `nil`, leaving the raw compiler error to stand alone.
  """
  @spec for_compile_failure(String.t()) :: String.t() | nil
  def for_compile_failure(output) when is_binary(output) do
    case expanding_macros(output) do
      [] -> nil
      macros -> macro_skip_hint(macros)
    end
  end

  @doc """
  The macro(s) to advise skipping, as distinct `{module_string, function_atom}`
  pairs read from the `expanding macro:` frames in `output`, in first-seen order.
  `[]` when there are none.

  Each compile error reports only its **innermost** macro — the one whose literal
  argument was actually mutated. A literal-only macro nested inside another
  (`if Size.megabytes(5)`) also lists the enclosing macros, but skipping those
  would needlessly hide valid mutants, so only the culprit is kept.

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
    A mutation broke the build by changing an argument that a macro needs as a
    compile-time literal — the macro raised while the compiler was expanding it.
    Mutare can't recover from this on its own, so the run is blocked until you tell
    it to skip the macro.

    Macro(s) that can't have their arguments mutated:

    #{bullets(macros)}

    Add this to .mutare.exs to skip them and unblock the run. Only these macros'
    arguments are left unmutated; the rest of your code is still mutated as usual:

    #{snippet(macros)}

    See `mix help mutare` for the `:macros` option.\
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
