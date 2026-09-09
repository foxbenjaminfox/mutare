defmodule Mutare.Sandbox.CompilerOptionsTest do
  use ExUnit.Case, async: true

  alias Mutare.Sandbox.CompilerOptions

  describe "erl_compiler_options/1 (metamutant compile speed)" do
    # Parse the produced string as Erlang terms, so every case proves we emit a
    # well-formed list the compiler can read (never a malformed value that could
    # break the single build).
    defp parse_terms(str) do
      {:ok, tokens, _} = :erl_scan.string(String.to_charlist(str <> ". "))
      {:ok, term} = :erl_parse.parse_term(tokens)
      term
    end

    test "with no inherited options, yields just the alias-pass-off option" do
      for none <- [nil, "", "   "] do
        assert CompilerOptions.erl_compiler_options(none) == "[no_ssa_opt_alias]"
        assert parse_terms(CompilerOptions.erl_compiler_options(none)) == [:no_ssa_opt_alias]
      end
    end

    test "an empty inherited list collapses to just our option" do
      assert CompilerOptions.erl_compiler_options("[]") == "[no_ssa_opt_alias]"
    end

    test "prepends our option to an inherited list, preserving the rest" do
      result = CompilerOptions.erl_compiler_options("[bin_opt_info, warn_missing_spec]")
      assert result == "[no_ssa_opt_alias, bin_opt_info, warn_missing_spec]"
      assert parse_terms(result) == [:no_ssa_opt_alias, :bin_opt_info, :warn_missing_spec]
    end

    test "wraps a bare (non-list) inherited term into a list with our option" do
      assert CompilerOptions.erl_compiler_options("bin_opt_info") ==
               "[no_ssa_opt_alias, bin_opt_info]"
    end

    test "preserves a nested term in the inherited list (strips outer brackets only)" do
      result = CompilerOptions.erl_compiler_options("[{d, [debug]}]")
      assert result == "[no_ssa_opt_alias, {d, [debug]}]"
      assert parse_terms(result) == [:no_ssa_opt_alias, {:d, [:debug]}]
    end

    test "always parses as an Erlang term list containing our option" do
      for inherited <- [nil, "", "[]", "[a, b]", "bare", "[{d, [x]}]"] do
        terms = parse_terms(CompilerOptions.erl_compiler_options(inherited))
        assert is_list(terms)
        assert :no_ssa_opt_alias in terms
      end
    end
  end

  test "compiler_env/0 sets ERL_COMPILER_OPTIONS with the alias-pass-off option" do
    assert [{"ERL_COMPILER_OPTIONS", value}] = CompilerOptions.compiler_env()
    assert value =~ "no_ssa_opt_alias"
  end

  describe "compile_args/1 (verify pass off, version-gated)" do
    # An unknown switch makes `mix compile` abort, sinking the one build — so the
    # gate must be exact: `--no-verification` exists since Elixir 1.19.
    test "passes --no-verification on 1.19 and later" do
      for version <- ["1.19.0", "1.19.5", "1.20.1", "1.21.0-dev"] do
        assert CompilerOptions.compile_args(version) == ["--no-verification"]
      end
    end

    test "passes nothing before 1.19 (the switch does not exist there)" do
      for version <- ["1.18.4", "1.17.3", "1.19.0-rc.0"] do
        assert CompilerOptions.compile_args(version) == []
      end
    end

    test "defaults to the running Elixir" do
      assert CompilerOptions.compile_args() == CompilerOptions.compile_args(System.version())
    end
  end

  describe "project_source/1" do
    test "renders keyword-do module bodies with an encoded hook atom" do
      for form <- ["defmodule", "Kernel.defmodule", "Elixir.Kernel.defmodule"] do
        assert {source, true} = CompilerOptions.project_source("#{form} Example, do: :ok")
        assert {:ok, _} = Code.string_to_quoted(source)
        assert source =~ "@before_compile :mutare_sandbox_compiler_options"
      end
    end

    test "leaves quoted definitions unchanged, including nested quotes and keyword-do bodies" do
      quoted = """
      quote do
        defmodule Quoted, do: :ok
        quote do
          Kernel.defmodule Nested do
            :ok
          end
        end
      end
      """

      source = """
      defmodule Example do
        def template do
          #{quoted}
        end
      end

      defmodule AfterQuote, do: :ok
      """

      assert {rendered, true} = CompilerOptions.project_source(source)

      assert length(Regex.scan(~r/@before_compile :mutare_sandbox_compiler_options/, rendered)) ==
               2

      expected = quoted |> Code.string_to_quoted!() |> Macro.to_string()

      {_ast, quotes} =
        rendered
        |> Code.string_to_quoted!()
        |> Macro.prewalk([], fn
          {:quote, _, _} = node, quotes -> {node, [Macro.to_string(node) | quotes]}
          node, quotes -> {node, quotes}
        end)

      assert expected in quotes
    end

    test "returns unparseable project templates byte-for-byte, reporting no hook" do
      for source <- ["defmodule <%= @module %>, do: :ok\n", "defmodule MissingEnd do\n", "[)\n"] do
        assert CompilerOptions.project_source(source) == {source, false}
      end
    end

    test "reports no hook for a mix.exs that defines no module of its own" do
      # A project built entirely in an externally required file. The rewrite has nothing to
      # hook, yet the source still comes back *changed* — the bootstrap is prepended
      # unconditionally — so the caller cannot read the outcome off the string.
      source = ~s|Code.require_file("build/project.exs", __DIR__)\n|

      assert {rendered, false} = CompilerOptions.project_source(source)
      assert rendered != source
      refute rendered =~ "@before_compile"
    end

    test "renders a dependency-free wrapper that reparses" do
      assert {source, true} =
               CompilerOptions.project_source("""
               defmodule Example.MixProject do
                 use Mix.Project
                 def project, do: [app: :example, version: "0.0.0"]
               end
               """)

      assert {:ok, _} = Code.string_to_quoted(source)
      assert source =~ "defoverridable project: 0"
      assert source =~ "@before_compile :mutare_sandbox_compiler_options"

      # `use Mix.Project` registers the after-compile hook but defines no `project/0`, so the
      # wrapper must check for the function too: `defoverridable` on a missing one aborts the
      # sandbox's mix.exs, replacing Mix's own legible complaint about the broken project.
      assert source =~ "Module.defines?(env.module, {:project, 0})"
    end
  end

  describe "seed_manifest/1" do
    test "adjusts only inference in recognized cache keys" do
      for {version, tail} <- [{26, [%{}, 0, 0]}, {29, ["/sandbox", %{}, 0, 0, {%{}, %{}}]}],
          options <- [[], [docs: false, infer_signatures: true, debug_info: false]],
          key <- [{options, ["lib"], false}, {options, ["lib"], "/sandbox", true}] do
        # Captured configuration containing the same option is unrelated data.
        sources = %{compile_env: [infer_signatures: true]}
        manifest = List.to_tuple([version, %{}, sources, %{}, [], key | tail])
        result = CompilerOptions.seed_manifest(manifest)

        expected =
          if :infer_signatures in Code.available_compiler_options(),
            do:
              put_elem(
                manifest,
                5,
                put_elem(key, 0, Keyword.put(options, :infer_signatures, false))
              ),
            else: manifest

        assert result == expected
        assert CompilerOptions.seed_manifest(result) == result
      end
    end

    test "leaves unknown layouts and Elixir 1.20 keys untouched" do
      for manifest <- [
            {:manifest, [infer_signatures: true]},
            {99, %{}, %{}, %{}, [], {[], ["lib"], false}, "/sandbox", %{}, 0, 0, {%{}, %{}}},
            {35, %{}, %{}, %{}, [], {[], ["lib"], false, false}, "/sandbox",
             %{infer_signatures: [:elixir]}, 0, 0, {%{}, %{}}},
            {29, %{}, %{}, %{}, [], :unknown, "/sandbox", %{}, 0, 0, {%{}, %{}}}
          ] do
        assert CompilerOptions.seed_manifest(manifest) == manifest
      end
    end
  end
end
