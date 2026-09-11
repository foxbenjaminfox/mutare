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

  The way out is to leave that macro's arguments as written by routing it `:raw`
  in `.mutare.exs` (the `:call_routes` option). This module recognises the situation
  from the failed compile's output, identifies the macro(s) at fault, and produces
  that advice — including a copy-pasteable snippet — so the error the user sees
  explains how to get unblocked instead of just echoing the raw compiler error.

  Returns `nil` for any other compile failure, where the raw error stands on its
  own.
  """

  alias Mutare.Sandbox.Command.Output
  alias Mutare.Transform.StructuralForms

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
  `[]` when there are none. The names of `culprits/1`, deduplicated.

      iex> Mutare.Poison.Hint.expanding_macros("expanding macro: Size.megabytes/1\\n")
      [{"Size", :megabytes}]
  """
  @spec expanding_macros(String.t()) :: [{String.t(), atom()}]
  def expanding_macros(output) when is_binary(output) do
    output
    |> culprits()
    |> Enum.map(fn {macro, _call_site} -> macro end)
    |> Enum.uniq()
  end

  @doc """
  The culprit macro of each stacktrace in `output`, paired with where it was invoked:
  `{{module_string, function_atom}, {file, line} | nil}`, in source order — one entry per
  stacktrace whose innermost frame names a macro we can advise on.

  Each compile error reports only its **innermost** macro — the one whose literal argument
  was actually mutated. A literal-only macro nested inside another (`if Size.megabytes(5)`)
  also lists the enclosing macros, but skipping those would needlessly hide valid mutants, so
  only the culprit is kept (the frames come from
  `Mutare.Sandbox.Command.Output.macro_expansion_stacks/1`, innermost first). The call site is
  the frame's own — the file whose metamutant holds the poisoning mutant — which is why
  `Mutare.Poison.macro_poison/3` reads this rather than `expanding_macros/1`.

      iex> Mutare.Poison.Hint.culprits("expanding macro: Size.megabytes/1\\n    lib/a.ex:8: A.f/0\\n")
      [{{"Size", :megabytes}, {"lib/a.ex", 8}}]
  """
  @spec culprits(String.t()) :: [{{String.t(), atom()}, {String.t(), pos_integer()} | nil}]
  def culprits(output) when is_binary(output) do
    output
    |> Output.macro_expansion_stacks()
    |> Enum.flat_map(fn [innermost | _enclosing] ->
      Enum.map(split_macro(innermost.name), &{&1, innermost.call_site})
    end)
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

  @doc """
  A copy-pasteable `:call_routes` suggestion for the block macros a *successful* run
  had to escalate (skip wholesale) during compile-poison recovery, or `nil` when there
  were none.

  Unlike `for_compile_failure/1` — which fires on an *unrecoverable* abort — this is the
  advice a run prints after it *recovered*: the metamutant compiled, but only because
  Mutare guessed a DSL body could be mutated, hit poison, and skipped the block at
  runtime. That recovery is rediscovered from scratch on every run (the dropped ids are
  in-memory only), so we hand the user the durable, name-based fix. Each escalated macro
  becomes a module-wildcard `{:*, :name, :raw}` route (the invocation's module is an
  unknown DSL we don't resolve), skipping that macro name wherever it appears.

  `escalations` is `Mutare.Run`'s `:recovery.escalated` (a list of
  `t:Mutare.Run.escalation/0`).

      iex> Mutare.Poison.Hint.escalation_note([%{macro: :guarded, file: "lib/x.ex", line: 3, count: 2}])
      ...> |> String.contains?("{:*, :guarded, :raw}")
      true
  """
  @spec escalation_note([Mutare.Run.escalation()]) :: String.t() | nil
  def escalation_note([]), do: nil

  def escalation_note(escalations) do
    macros = escalations |> Enum.map(& &1.macro) |> Enum.uniq()

    """
    Mutare recovered from compile-poisoning by skipping #{macro_count(macros)} whole
    unknown macro block#{plural(macros)} — it mutated the block body on the guess a DSL
    unquotes it into a function, hit code that wouldn't compile, and dropped every mutant
    in the block. That recovery is rediscovered on every run (the extra rebuilds are not
    remembered), so pin it in .mutare.exs to skip these macros up front:

    #{wildcard_snippet(macros)}

    #{macro_routes_footer()}\
    """
  end

  @doc """
  A copy-pasteable `:call_routes` suggestion for the inline DSL macros a *successful* run
  had to skip via the macro-expansion fallback (`Mutare.Poison.macro_poison/2`), or `nil`
  when there were none.

  The sibling of `escalation_note/1` for inline macros rather than block macros: a mutation
  wouldn't compile inside a macro that rewrites its argument at compile time, so Mutare
  dropped that macro's mutants and rebuilt. Because the compiler *named* the macro (an
  `expanding macro:` frame), the module is known — so unlike the block case's `{:*, …}`
  wildcard this suggests the precise `{Module, :fun, :raw}`. That recovery is rediscovered
  (and its rebuilds repaid) on every run, so pinning it is the durable fix.

  `macro_skipped` is `Mutare.Run`'s `:recovery.macro_skipped` (a list of
  `%{module: module_string, macro: fun_atom}`).

      iex> Mutare.Poison.Hint.macro_skip_note([%{module: "Ecto.Query", macro: :from}])
      ...> |> String.contains?("{Ecto.Query, :from, :raw}")
      true
  """
  @spec macro_skip_note([%{module: String.t(), macro: atom()}]) :: String.t() | nil
  def macro_skip_note([]), do: nil

  def macro_skip_note(macro_skipped) do
    pairs = macro_skipped |> Enum.map(&{&1.module, &1.macro}) |> Enum.uniq()

    """
    Mutare recovered from compile-poisoning by skipping #{macro_count(pairs)} inline DSL
    macro#{plural(pairs)} — a mutation wouldn't compile inside #{one_or_them(pairs)}, so every
    mutant in #{its_or_their(pairs)} calls was dropped. That recovery (and its extra rebuilds)
    is repaid on every run, so pin it in .mutare.exs to skip #{one_or_them(pairs)} up front:

    #{snippet(pairs)}

    #{macro_routes_footer()}\
    """
  end

  # The shared closing line of both `:call_routes` remediation notes (block + inline).
  defp macro_routes_footer do
    "Only these macros' arguments are left unmutated; the rest of your code is still\n" <>
      "mutated as usual. See `mix help mutare` for the `:call_routes` option."
  end

  defp one_or_them([_]), do: "it"
  defp one_or_them(_), do: "them"

  defp its_or_their([_]), do: "its"
  defp its_or_their(_), do: "their"

  defp macro_count([_]), do: "1"
  defp macro_count(macros), do: "#{length(macros)}"

  defp plural([_]), do: ""
  defp plural(_macros), do: "s"

  # A copy-pasteable `.mutare.exs` keyword list of module-wildcard skips — one
  # `{:*, :name, :raw}` per escalated macro name, skipping it in any module (the
  # invocation's module is an unknown DSL Mutare doesn't resolve to a concrete name).
  defp wildcard_snippet(macros) do
    entries =
      Enum.map_join(macros, ",\n", fn macro ->
        "        {:*, #{inspect(macro)}, :raw}"
      end)

    """
        [
          call_routes: [
    #{entries}
          ]
        ]\
    """
  end

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

    See `mix help mutare` for the `:call_routes` option.\
    """
  end

  defp bullets(macros) do
    Enum.map_join(macros, "\n", fn {module, fun} -> "  * #{module}.#{fun}" end)
  end

  defp route_entry({module, fun}) do
    case StructuralForms.hint_treatment_for(module, fun) do
      nil ->
        "        # #{module}.#{fun} cannot be named by a route (a definition or compiler " <>
          "syntax); use `# mutare:ignore` around the offending code"

      treatment ->
        "        {#{module}, #{inspect(fun)}, #{inspect(treatment)}}"
    end
  end

  # A copy-pasteable `.mutare.exs` keyword list. One arity-agnostic 3-tuple per
  # macro (`{Module, :fun, :raw}`), so every arity of the macro is skipped. A head Mutare
  # analyzes structurally (`Kernel.in/2`, say) takes `:skip` — the only route it accepts — and
  # a definition (`Kernel.def/2`) takes no route at all, so it gets a comment pointing at
  # `# mutare:ignore` instead (`Mutare.Transform.StructuralForms`).
  defp snippet(macros) do
    entries = Enum.map_join(macros, ",\n", &route_entry/1)

    """
        [
          call_routes: [
    #{entries}
          ]
        ]\
    """
  end
end
