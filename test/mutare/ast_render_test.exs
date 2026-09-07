defmodule Mutare.ASTRenderTest do
  # `async: false`: the test changes the VM's working directory (restored on the way out).
  use ExUnit.Case, async: false

  alias Mutare.AST

  # Rendering must not evaluate the *target* project's `.formatter.exs` — Sourceror does so
  # by default, on every call, to read `locals_without_parens`, and Mix refuses an
  # `import_deps` it cannot resolve. A formatter file naming an unknown dependency stands
  # in for every way that lookup can fail mid-run.
  test "rendering never consults the working directory's .formatter.exs" do
    dir = Path.join(System.tmp_dir!(), "mutare_ast_render_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, ".formatter.exs"), "[import_deps: [:mutare_no_such_dep]]\n")

    File.cd!(dir, fn ->
      # Bare: Mix raises on the formatter config. Pinned: renders — a parsed call keeps the
      # spelling its metadata records, and a node built without metadata gets parentheses
      # (`foo`, not `assert`: ExUnit's macros are in the formatter's built-in no-parens list).
      assert_raise Mix.Error, ~r/Unknown dependency :mutare_no_such_dep/, fn ->
        Sourceror.to_string(AST.parse!("assert x"))
      end

      assert AST.to_string(AST.parse!("assert x")) == "assert x"
      assert AST.to_string(quote(do: foo(x))) == "foo(x)"
      assert Sourceror.to_string(AST.parse!("assert x"), AST.render_opts()) == "assert x"
      assert Mutare.Transform.Render.to_source(AST.parse!("assert x")) == "assert x"
    end)
  end
end
