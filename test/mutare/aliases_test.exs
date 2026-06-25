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

  defp register_alias(source, env) do
    source
    |> Sourceror.parse_string!()
    |> Aliases.register(env)
  end

  describe "resolved_module/2 (the reader)" do
    test "returns the stamped module when present, the literal path otherwise" do
      assert Aliases.resolved_module([mutare_alias: [:String]], [:S]) == [:String]
      assert Aliases.resolved_module([line: 1], [:Enum]) == [:Enum]
      # A non-keyword meta (defensive) falls back to the literal.
      assert Aliases.resolved_module(nil, [:Enum]) == [:Enum]
    end
  end

  describe "resolve_path/2" do
    test "an atom-module alias resolves only a lone segment" do
      env = %{B: :binary}

      assert Aliases.resolve_path([:B], env) == :binary
      assert Aliases.resolve_path([:B, :Sub], env) == [:B, :Sub]
    end

    test "non-path terms pass through unchanged" do
      assert Aliases.resolve_path(:binary, %{B: [:String]}) == :binary

      assert Aliases.resolve_path({:__MODULE__, [], nil}, %{B: [:String]}) ==
               {:__MODULE__, [], nil}
    end

    test "a leading Elixir segment (fully-qualified prefix) is stripped" do
      # `Elixir.String` *is* `String` — the alias-proof escape `Calls.qualifier/1` emits.
      assert Aliases.resolve_path([Elixir, :String], %{}) == [:String]
      assert Aliases.resolve_path([Elixir, :My, :Mod], %{}) == [:My, :Mod]
    end

    test "the Elixir prefix is alias-proof: the rest is NOT re-resolved against the env" do
      # The crucial distinction: `Elixir.String` ignores any alias, so even with `String`
      # rebound to a local module the fully-qualified path stays the real `String` — whereas a
      # *bare* `String` would resolve to the alias target.
      env = %{String: [:Wrong]}

      assert Aliases.resolve_path([Elixir, :String], env) == [:String]
      assert Aliases.resolve_path([:String], env) == [:Wrong]
    end

    test "a lone Elixir (root namespace, never a call target) is left untouched" do
      assert Aliases.resolve_path([Elixir], %{}) == [Elixir]
    end
  end

  describe "stamp_module/2" do
    test "leaves non-alias nodes unchanged" do
      node = {:__MODULE__, [line: 1], nil}

      assert Aliases.stamp_module(node, %{S: [:String]}) == node
    end

    test "leaves clean metadata when the written path is already resolved" do
      node = {:__aliases__, [line: 1], [:String]}

      assert Aliases.stamp_module(node, %{}) == node
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

    test "require with :as introduces an alias like `alias`" do
      calls =
        resolved("""
        defmodule M do
          require String, as: S
          def up(x), do: S.upcase(x)
        end
        """)

      assert calls[:upcase] == {[:S], [:String]}
    end

    test "a bare require (no :as) introduces no alias" do
      calls =
        resolved("""
        defmodule M do
          require Integer
          def up(x), do: Integer.foo(x)
        end
        """)

      # `Integer` is the literal module, unaffected; the bare require bound no name.
      assert calls[:foo] == {[:Integer], [:Integer]}
    end

    test "alias with :as overwrites an earlier binding for the same name" do
      calls =
        resolved("""
        defmodule M do
          alias Old.Strings, as: S
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

    test "plain alias overwrites an earlier binding for the same introduced name" do
      calls =
        resolved("""
        defmodule M do
          alias Old.Strings
          alias My.Strings
          def up(x), do: Strings.upcase(x)
        end
        """)

      assert calls[:upcase] == {[:Strings], [:My, :Strings]}
    end

    test "an alias target whose first segment is aliased keeps trailing segments" do
      calls =
        resolved("""
        defmodule M do
          alias MyApp, as: Root
          alias Root.Strings, as: S
          def up(x), do: S.upcase(x)
        end
        """)

      assert calls[:upcase] == {[:S], [:MyApp, :Strings]}
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

    test "an atom-module alias with :as overwrites an earlier binding" do
      calls =
        resolved("""
        defmodule M do
          alias Old.Binary, as: B
          alias :binary, as: B
          def f(x), do: B.split(x, ",")
        end
        """)

      assert calls[:split] == {[:B], :binary}
    end

    test "an atom-module alias without :as binds nothing" do
      env = %{B: [:Existing]}

      assert register_alias("alias :binary", env) == env
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

    test "a fully-qualified `Elixir.`-prefixed call resolves to the bare module key" do
      # The easy case the machinery used to skip: `Elixir.String.upcase` carries the written
      # path `[Elixir, :String]`, but resolves (and is stamped) to `[:String]` — the key the
      # call families match — so the call is no longer silently missed. The literal path keeps
      # the `Elixir.` so the rebuilt swap (and the diff) stays faithful.
      calls =
        resolved("""
        defmodule M do
          def up(x), do: Elixir.String.upcase(x)
        end
        """)

      assert calls[:upcase] == {[Elixir, :String], [:String]}
    end

    test "the Elixir prefix is alias-proof even under a shadowing alias" do
      # `alias Wrong, as: String` rebinds the bare name `String`, but `Elixir.String` is the
      # absolute, fully-qualified module and ignores the alias — so the prefixed call still
      # resolves to the real `[:String]`, while the bare `String.downcase` resolves to the
      # shadowed `[:Wrong]`. The two MUST differ.
      calls =
        resolved("""
        defmodule M do
          alias Wrong, as: String
          def up(x), do: Elixir.String.upcase(x)
          def down(x), do: String.downcase(x)
        end
        """)

      assert calls[:upcase] == {[Elixir, :String], [:String]}
      assert calls[:downcase] == {[:String], [:Wrong]}
    end
  end

  describe "register/2 — malformed alias directives" do
    test "ignores a multi-alias whose base or child is not an atom path" do
      env = %{Existing: [:Existing]}

      bad_children =
        {:alias, [],
         [
           {{:., [], [{:__aliases__, [], [:My]}, :{}]}, [], :not_children}
         ]}

      bad_base =
        {:alias, [],
         [
           {{:., [], [{:__aliases__, [], [{:__MODULE__, [], nil}]}, :{}]}, [],
            [{:__aliases__, [], [:Sub]}]}
         ]}

      bad_child =
        {:alias, [],
         [
           {{:., [], [{:__aliases__, [], [:My]}, :{}]}, [],
            [{:__aliases__, [], [{:__MODULE__, [], nil}]}]}
         ]}

      assert Aliases.register(bad_children, env) == env
      assert Aliases.register(bad_base, env) == env
      assert Aliases.register(bad_child, env) == env
    end

    test "ignores a simple alias whose path is not all atoms" do
      env = %{Existing: [:Existing]}

      bad_alias =
        {:alias, [],
         [{:__aliases__, [], [{:__MODULE__, [], nil}, :Sub]}, [as: {:__aliases__, [], [:Sub]}]]}

      assert Aliases.register(bad_alias, env) == env
    end

    test "only the :as option overrides the introduced name" do
      env = %{Existing: [:Existing]}

      assert Aliases.register(
               {:alias, [],
                [{:__aliases__, [], [:Foo, :Bar]}, [bee: {:__aliases__, [], [:Baz]}]]},
               env
             ) == Map.put(env, :Bar, [:Foo, :Bar])
    end

    test "non-keyword options are treated as no :as option" do
      env = %{Existing: [:Existing]}

      assert Aliases.register(
               {:alias, [], [{:__aliases__, [], [:Foo, :Bar]}, :not_keyword_options]},
               env
             ) == Map.put(env, :Bar, [:Foo, :Bar])
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
