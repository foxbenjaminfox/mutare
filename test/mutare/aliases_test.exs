defmodule Mutare.AliasesTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Aliases, Resolve}

  # Annotate `source` (through the unified resolution walk), then return
  # `{literal_path, resolved_path}` for every remote call, keyed by the called function name —
  # the contract a mutator reads.
  defp resolved(source) do
    source
    |> Sourceror.parse_string!()
    |> Resolve.annotate()
    |> collect_calls()
  end

  defp collect_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, %{}, fn
        {{:., _, [{:__aliases__, am, path}, fun]}, _, args} = node, acc when is_list(args) ->
          {node, Map.put(acc, fun, {path, Aliases.resolved_module(am, path)})}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  describe "resolved_module/2 (the reader)" do
    test "returns the stamped module when present, the literal path otherwise" do
      assert Aliases.resolved_module([mutare_alias: [:String]], [:S]) == [:String]
      assert Aliases.resolved_module([line: 1], [:Enum]) == [:Enum]
      # A non-keyword meta (defensive) falls back to the literal.
      assert Aliases.resolved_module(nil, [:Enum]) == [:Enum]
    end
  end

  describe "annotate/1 — alias forms" do
    test "alias with :as resolves the rebound name" do
      calls =
        resolved("""
        defmodule M do
          alias String, as: S
          def up(x), do: S.upcase(x)
        end
        """)

      assert calls[:upcase] == {[:S], [:String]}
    end

    test "plain alias resolves the last segment" do
      calls =
        resolved("""
        defmodule M do
          alias My.Strings
          def up(x), do: Strings.upcase(x)
        end
        """)

      assert calls[:upcase] == {[:Strings], [:My, :Strings]}
    end

    test "multi-alias resolves each child on the shared base" do
      calls =
        resolved("""
        defmodule M do
          alias My.{Strings, Lists}
          def up(x), do: Strings.upcase(x)
          def rev(x), do: Lists.reverse(x)
        end
        """)

      assert calls[:upcase] == {[:Strings], [:My, :Strings]}
      assert calls[:reverse] == {[:Lists], [:My, :Lists]}
    end

    test "an unaliased call resolves to itself and carries no stamp" do
      calls =
        resolved("""
        defmodule M do
          def up(x), do: String.upcase(x)
        end
        """)

      assert calls[:upcase] == {[:String], [:String]}
    end

    test "an alias whose target is itself aliased resolves through the env (not the intermediate)" do
      # The chained-alias bug: `alias MyApp, as: String` rebinds `String` to a local module,
      # then `alias String, as: S` must bind `S` to MyApp (the real module) — NOT to the
      # intermediate `String`, which would make `S.upcase` masquerade as a stdlib call.
      calls =
        resolved("""
        defmodule M do
          alias MyApp, as: String
          alias String, as: S
          def up(x), do: S.upcase(x)
        end
        """)

      assert calls[:upcase] == {[:S], [:MyApp]}
    end

    test "a multi-alias on an aliased base resolves the base through the env" do
      calls =
        resolved("""
        defmodule M do
          alias My.Lib, as: Lib
          alias Lib.{Strings, Lists}
          def up(x), do: Strings.upcase(x)
          def rev(x), do: Lists.reverse(x)
        end
        """)

      assert calls[:upcase] == {[:Strings], [:My, :Lib, :Strings]}
      assert calls[:reverse] == {[:Lists], [:My, :Lib, :Lists]}
    end

    test "a plain alias on an aliased single-segment target keeps the written name" do
      # `alias MyApp, as: String` then a bare `alias String`: the introduced name is the
      # written `String`, bound to the resolved MyApp.
      calls =
        resolved("""
        defmodule M do
          alias MyApp, as: String
          alias String
          def up(x), do: String.upcase(x)
        end
        """)

      assert calls[:upcase] == {[:String], [:MyApp]}
    end

    test "an alias of an Erlang atom module resolves the name to the atom" do
      # `alias :binary, as: B` binds `B` to the atom `:binary` (not a path), so `B.split`
      # resolves to `:binary` — the same module key a direct `:binary.split` carries.
      calls =
        resolved("""
        defmodule M do
          alias :binary, as: B
          def f(x), do: B.split(x, ",")
        end
        """)

      assert calls[:split] == {[:B], :binary}
    end

    test "a __MODULE__-relative alias is left unresolved (can't name a concrete module)" do
      calls =
        resolved("""
        defmodule M do
          alias __MODULE__.Sub
          def go(x), do: Sub.run(x)
        end
        """)

      assert calls[:run] == {[:Sub], [:Sub]}
    end
  end

  describe "annotate/1 — lexical scoping" do
    test "aliasing a stdlib name to a local module shadows it (resolves away from stdlib)" do
      # The latent-bug case: `alias MyApp.Enum` makes `Enum.filter` refer to MyApp.Enum,
      # so resolution points it at [:MyApp, :Enum], NOT [:Enum] — the mutators won't match.
      calls =
        resolved("""
        defmodule M do
          alias MyApp.Enum
          def f(xs), do: Enum.filter(xs, & &1)
        end
        """)

      assert calls[:filter] == {[:Enum], [:MyApp, :Enum]}
    end

    test "an alias is textual: it applies only to calls after it" do
      # Distinct function names so each call is observed independently (the collector
      # keys by called function). `length` precedes the alias; `duplicate` follows it.
      calls =
        resolved("""
        defmodule M do
          def a(x), do: String.length(x)
          alias My.Str, as: String
          def b(x), do: String.duplicate(x, 2)
        end
        """)

      assert calls[:length] == {[:String], [:String]}
      assert calls[:duplicate] == {[:String], [:My, :Str]}
    end

    test "a nested module inherits the enclosing aliases" do
      calls =
        resolved("""
        defmodule Outer do
          alias My.Strings, as: S
          defmodule Inner do
            def up(x), do: S.upcase(x)
          end
        end
        """)

      assert calls[:upcase] == {[:S], [:My, :Strings]}
    end

    test "an alias inside a nested module does not leak to the outer scope" do
      calls =
        resolved("""
        defmodule Outer do
          defmodule Inner do
            alias My.Strings, as: S
          end

          def up(x), do: S.upcase(x)
        end
        """)

      # `S` was only aliased inside Inner, so in Outer it stays unresolved.
      assert calls[:upcase] == {[:S], [:S]}
    end

    test "an alias inside a function body scopes to the rest of that body" do
      calls =
        resolved("""
        defmodule M do
          def go(x) do
            alias My.Strings, as: S
            S.upcase(x)
          end
        end
        """)

      assert calls[:upcase] == {[:S], [:My, :Strings]}
    end
  end
end
