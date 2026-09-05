defmodule Mutare.Poison.HintTest do
  @moduledoc "Remediation hints for an unrecoverable poisoned compile."
  use ExUnit.Case, async: true

  alias Mutare.Poison.Hint

  doctest Hint

  describe "expanding_macros/1" do
    test "requires a binary (rejects a non-string output)" do
      # Match the exact message (naming `expanding_macros/1` itself), not just the exception
      # class — the body's own `String.split/2` call also raises `FunctionClauseError` for a
      # non-binary, so asserting on class alone can't tell this guard apart from a dropped one.
      assert_raise FunctionClauseError,
                   "no function clause matching in Mutare.Poison.Hint.expanding_macros/1",
                   fn -> Hint.expanding_macros(:not_a_string) end
    end

    test "extracts a single macro from an expansion frame" do
      output = """
      == Compilation error in file lib/foo.ex ==
      ** (FunctionClauseError) no function clause matching in Size.megabytes/1
          expanding macro: Size.megabytes/1
          lib/foo.ex:8: Foo.limit/0
      """

      assert Hint.expanding_macros(output) == [{"Size", :megabytes}]
    end

    test "handles nested module paths" do
      output = "    expanding macro: MyApp.DSL.Helpers.field/2\n"
      assert Hint.expanding_macros(output) == [{"MyApp.DSL.Helpers", :field}]
    end

    test "keeps only the innermost frame, dropping an enclosing wrapper macro" do
      # `if Size.megabytes(5)` — the compiler prints the failing macro stack
      # innermost-first, so `Size.megabytes` (whose literal arg was mutated) leads
      # and the enclosing `Kernel.if` follows. Advising `{Kernel, :if, :raw}` would
      # stop Mutare descending into every `if`, so the outer frame must be dropped.
      output = """
      == Compilation error in file lib/usage.ex ==
      ** (FunctionClauseError) no function clause matching in Size.megabytes/1
          expanding macro: Size.megabytes/1
          lib/usage.ex:4: Usage.limit/0
          (elixir #{System.version()}) expanding macro: Kernel.if/2
          lib/usage.ex:4: Usage.limit/0
      """

      assert Hint.expanding_macros(output) == [{"Size", :megabytes}]
    end

    test "takes one innermost culprit per error, dedups across errors, first-seen order" do
      # Each failing file is its own stacktrace (a fresh `** (Error)` header), so the
      # innermost frame of each is captured; an outer `Kernel.if` is dropped, the
      # same macro at two arities collapses to one, and order is first-seen.
      output = """
      == Compilation error in file lib/a.ex ==
      ** (FunctionClauseError) no function clause matching in A.one/1
          expanding macro: A.one/1
          lib/a.ex:3: AMod.f/0
          (elixir #{System.version()}) expanding macro: Kernel.if/2
          lib/a.ex:3: AMod.f/0
      == Compilation error in file lib/b.ex ==
      ** (ArgumentError) argument error
          expanding macro: B.two/2
          lib/b.ex:5: BMod.g/0
      == Compilation error in file lib/a.ex ==
      ** (FunctionClauseError) no function clause matching in A.one/2
          expanding macro: A.one/2
          lib/a.ex:9: AMod.h/0
      """

      assert Hint.expanding_macros(output) == [{"A", :one}, {"B", :two}]
    end

    test "ignores a malformed/unqualified capture rather than emit bad advice" do
      # A function part that looks like a module segment (uppercase lead) is not a
      # macro name we can advise on; an unqualified name has no module to skip.
      assert Hint.expanding_macros("expanding macro: Foo.Bar/1\n") == []
      assert Hint.expanding_macros("expanding macro: bare/1\n") == []
    end

    test "no expansion frame yields []" do
      assert Hint.expanding_macros("** (CompileError) undefined function foo/0") == []
    end

    test "stays armed across intervening non-frame lines until the real expanding-macro frame" do
      # A stray line between the exception header and the actual `expanding macro:` frame
      # must not disarm the capture — otherwise the real frame right after it is missed.
      output = """
      ** (FunctionClauseError) no function clause matching in Size.megabytes/1
          (stacktrace) Elixir.Kernel.some_helper/1
          (stacktrace) Elixir.Kernel.another_helper/2
          expanding macro: Size.megabytes/1
          lib/usage.ex:4: Usage.limit/0
      """

      assert Hint.expanding_macros(output) == [{"Size", :megabytes}]
    end

    test "a function name starting exactly at the boundary letters 'a'/'z' is accepted" do
      assert Hint.expanding_macros("expanding macro: Mod.amethod/1\n") == [{"Mod", :amethod}]
      assert Hint.expanding_macros("expanding macro: Mod.zmethod/1\n") == [{"Mod", :zmethod}]
    end

    test "a function name starting one character outside a/z is rejected (no bad advice)" do
      # Adjacent to the `?a..?z` range on either side: "`" (96, just below "a") and "{"
      # (123, just above "z") must NOT be treated as valid function-name leads.
      assert Hint.expanding_macros("expanding macro: Mod.`method/1\n") == []
      assert Hint.expanding_macros("expanding macro: Mod.{method/1\n") == []
    end

    test "a function name starting with `_` is accepted (the other half of the guard)" do
      assert Hint.expanding_macros("expanding macro: Mod._private_method/1\n") ==
               [{"Mod", :_private_method}]
    end
  end

  describe "for_compile_failure/1" do
    test "requires a binary (rejects a non-string output)" do
      # Same reasoning as `expanding_macros/1` above: pin the exact message (naming
      # `for_compile_failure/1`), since a dropped guard here would still raise
      # `FunctionClauseError` — just from the `expanding_macros/1` call inside the body.
      assert_raise FunctionClauseError,
                   "no function clause matching in Mutare.Poison.Hint.for_compile_failure/1",
                   fn -> Hint.for_compile_failure(:not_a_string) end
    end

    test "nil when no recognised cause" do
      assert Hint.for_compile_failure("** (CompileError) something unrelated") == nil
    end

    test "explains the macro-literal cause and emits a copy-pasteable :skip snippet" do
      output = """
      == Compilation error in file lib/foo.ex ==
      ** (FunctionClauseError) no function clause matching in Size.megabytes/1
          expanding macro: Size.megabytes/1
          lib/foo.ex:8: Foo.limit/0
      """

      hint = Hint.for_compile_failure(output)

      assert hint =~ "expanding it"
      assert hint =~ "compile-time literal"
      assert hint =~ "* Size.megabytes"
      assert hint =~ ".mutare.exs"
      assert hint =~ "call_routes: ["
      assert hint =~ "{Size, :megabytes, :raw}"
    end

    test "the snippet is valid Elixir that resolves through Mutare.CallRouting.Registry" do
      output = """
      ** (FunctionClauseError) no function clause matching in Size.megabytes/1
          expanding macro: Size.megabytes/1
          lib/a.ex:3: A.f/0
      ** (ArgumentError) argument error
          expanding macro: My.App.field/2
          lib/b.ex:5: B.g/0
      """

      hint = Hint.for_compile_failure(output)

      # Pull the `[ call_routes: [...] ]` snippet out of the prose and evaluate it, then
      # confirm it round-trips through the real `:call_routes` resolver — so the advice we
      # print is exactly what the user can paste into `.mutare.exs`.
      lines = String.split(hint, "\n")
      start = Enum.find_index(lines, &(&1 == "    ["))
      rest = Enum.drop(lines, start)
      stop = Enum.find_index(rest, &(&1 == "    ]"))
      snippet = rest |> Enum.take(stop + 1) |> Enum.join("\n")

      {config, _} = Code.eval_string(snippet)
      specs = Mutare.CallRouting.Registry.resolve(config[:call_routes])

      assert Enum.map(specs, &{&1.name, &1.arity, &1.args}) ==
               [{:megabytes, :any, :raw}, {:field, :any, :raw}]

      # The bullet list joins multiple macros with a real newline, one bullet per line — not ""
      # (which would run every macro's bullet together) or a stray "mutare" separator.
      assert hint =~ "  * Size.megabytes\n  * My.App.field"
    end
  end

  describe "escalation_note/1" do
    test "nil when nothing was escalated" do
      assert Hint.escalation_note([]) == nil
    end

    test "explains the recovery and emits a module-wildcard :skip snippet per macro" do
      note =
        Hint.escalation_note([
          %{macro: :guarded, file: "lib/a.ex", line: 3, count: 4},
          %{macro: :parsec, file: "lib/b.ex", line: 9, count: 2}
        ])

      assert note =~ "recovered from compile-poisoning"
      assert note =~ "2 whole"
      assert note =~ "rediscovered on every run"
      assert note =~ ".mutare.exs"
      assert note =~ "{:*, :guarded, :raw}"
      assert note =~ "{:*, :parsec, :raw}"
      assert note =~ "`:call_routes`"
    end

    test "dedups a macro escalated at more than one invocation" do
      note =
        Hint.escalation_note([
          %{macro: :guarded, file: "lib/a.ex", line: 3, count: 4},
          %{macro: :guarded, file: "lib/a.ex", line: 8, count: 1}
        ])

      # One route per distinct macro name, and the singular "1 whole … block".
      assert note =~ "1 whole"
      routes = note |> String.split("\n") |> Enum.filter(&(&1 =~ "{:*,"))
      assert routes == ["        {:*, :guarded, :raw}"]
    end

    test "the snippet is valid Elixir that resolves through Mutare.CallRouting.Registry" do
      note = Hint.escalation_note([%{macro: :guarded, file: "lib/a.ex", line: 3, count: 4}])

      lines = String.split(note, "\n")
      start = Enum.find_index(lines, &(&1 == "    ["))
      rest = Enum.drop(lines, start)
      stop = Enum.find_index(rest, &(&1 == "    ]"))
      snippet = rest |> Enum.take(stop + 1) |> Enum.join("\n")

      {config, _} = Code.eval_string(snippet)
      specs = Mutare.CallRouting.Registry.resolve(config[:call_routes])

      assert Enum.map(specs, &{&1.module, &1.name, &1.args}) == [{:*, :guarded, :raw}]
    end
  end

  describe "macro_skip_note/1" do
    test "returns nil when nothing was skipped" do
      assert Hint.macro_skip_note([]) == nil
    end

    test "suggests :skip for a structural Kernel head and no route at all for a definition" do
      # `{Kernel, :in, :raw}` would be rejected by `Options.new/1` (a structural head takes only
      # `:skip`), and no route may name `def`; a pasted hint must never trip either rule.
      note =
        Hint.macro_skip_note([
          %{module: "Kernel", macro: :in},
          %{module: "Kernel", macro: :def},
          %{module: "Kernel", macro: :sigil_r}
        ])

      assert note =~ "{Kernel, :in, :skip}"
      assert note =~ "{Kernel, :sigil_r, :raw}"
      assert note =~ "# Kernel.def cannot be named by a route"
      refute note =~ "{Kernel, :def,"
    end

    test "suggests a copy-pasteable module-qualified {Module, :fun, :raw} route" do
      note = Hint.macro_skip_note([%{module: "Ecto.Query", macro: :from}])

      lines = String.split(note, "\n")
      start = Enum.find_index(lines, &(&1 == "    ["))
      rest = Enum.drop(lines, start)
      stop = Enum.find_index(rest, &(&1 == "    ]"))
      snippet = rest |> Enum.take(stop + 1) |> Enum.join("\n")

      # Evaluates to a well-formed, module-qualified route (unlike the block case's
      # `{:*, …}` wildcard) — the module came from the compiler's `expanding macro:` frame.
      {config, _} = Code.eval_string(snippet)
      assert config[:call_routes] == [{Ecto.Query, :from, :raw}]
    end
  end
end
