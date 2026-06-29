defmodule Mutare.Poison.HintTest do
  @moduledoc "Remediation hints for an unrecoverable poisoned compile."
  use ExUnit.Case, async: true

  alias Mutare.Poison.Hint

  doctest Hint

  describe "expanding_macros/1" do
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
      # and the enclosing `Kernel.if` follows. Advising `{Kernel, :if, :skip}` would
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
  end

  describe "for_compile_failure/1" do
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
      assert hint =~ "macro_routes: ["
      assert hint =~ "{Size, :megabytes, :skip}"
    end

    test "the snippet is valid Elixir that resolves through Mutare.MacroRouting.Registry" do
      output = """
      ** (FunctionClauseError) no function clause matching in Size.megabytes/1
          expanding macro: Size.megabytes/1
          lib/a.ex:3: A.f/0
      ** (ArgumentError) argument error
          expanding macro: My.App.field/2
          lib/b.ex:5: B.g/0
      """

      hint = Hint.for_compile_failure(output)

      # Pull the `[ macro_routes: [...] ]` snippet out of the prose and evaluate it, then
      # confirm it round-trips through the real `:macro_routes` resolver — so the advice we
      # print is exactly what the user can paste into `.mutare.exs`.
      lines = String.split(hint, "\n")
      start = Enum.find_index(lines, &(&1 == "    ["))
      rest = Enum.drop(lines, start)
      stop = Enum.find_index(rest, &(&1 == "    ]"))
      snippet = rest |> Enum.take(stop + 1) |> Enum.join("\n")

      {config, _} = Code.eval_string(snippet)
      specs = Mutare.MacroRouting.Registry.resolve(config[:macro_routes])

      assert Enum.map(specs, &{&1.name, &1.arity, &1.args}) ==
               [{:megabytes, :any, :skip}, {:field, :any, :skip}]
    end
  end
end
