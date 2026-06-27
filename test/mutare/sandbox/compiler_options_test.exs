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
end
