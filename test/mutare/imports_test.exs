defmodule Mutare.ImportsTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Imports, Resolve}

  # Annotate `source` (through the unified resolution walk), then return
  # `%{fun => resolution}` for every bare call, where `resolution` is
  # `{module, :bare | :qualify}` (an imported call), `:kernel_displaced`, or absent (an
  # unresolved local / default-Kernel call) — the contract a mutator reads.
  defp resolved(source) do
    source
    |> Sourceror.parse_string!()
    |> Resolve.annotate()
    |> collect_calls()
  end

  defp collect_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, %{}, fn
        {fun, meta, args} = node, acc when is_atom(fun) and is_list(args) ->
          cond do
            (import_ = Imports.resolved_import(meta)) != nil -> {node, Map.put(acc, fun, import_)}
            Imports.kernel_displaced?(meta) -> {node, Map.put(acc, fun, :kernel_displaced)}
            true -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    calls
  end

  describe "the readers" do
    test "resolved_import/1 returns the stamp or nil" do
      assert Imports.resolved_import(mutare_import: {[:Enum], :bare}) == {[:Enum], :bare}
      assert Imports.resolved_import(line: 1) == nil
      assert Imports.resolved_import(nil) == nil
    end

    test "import_witness/1 returns the compile-time witness or nil" do
      assert Imports.import_witness(mutare_import_witness: {[:Enum], :reject, 2}) ==
               {[:Enum], :reject, 2}

      assert Imports.import_witness(line: 1) == nil
      assert Imports.import_witness(nil) == nil
    end

    test "kernel_displaced?/1 reads the flag, defaulting false" do
      assert Imports.kernel_displaced?(mutare_kernel_displaced: true) == true
      assert Imports.kernel_displaced?(line: 1) == false
      assert Imports.kernel_displaced?(nil) == false
    end
  end

  describe "whole-module import" do
    test "a bare call to an exported function resolves to the module (bare rebuild)" do
      calls =
        resolved("""
        defmodule M do
          import Enum
          def f(xs), do: reject(xs, & &1)
        end
        """)

      assert calls[:reject] == {[:Enum], :bare}
    end

    test "a bare call the module does not export is left unresolved (likely a local)" do
      # Enum has no `reject/3`; per Elixir, a coexisting local `reject/3` is legal — so the
      # arity-3 call must NOT be attributed to Enum (it would wrongly fire an arity-blind
      # family). Only the genuine `reject/2` resolves.
      calls =
        resolved("""
        defmodule M do
          import Enum
          def reject(a, b, c), do: {a, b, c}
          def two(xs), do: reject(xs, & &1)
          def three(xs), do: reject(xs, 1, 2)
        end
        """)

      assert calls[:reject] == {[:Enum], :bare}
    end

    test "a same-named local with no import is not resolved" do
      calls =
        resolved("""
        defmodule M do
          def reject(a, b), do: {a, b}
          def f(xs), do: reject(xs, 1)
        end
        """)

      refute Map.has_key?(calls, :reject)
    end

    test "a whole import that is not the sole import qualifies (a sibling could be ambiguous)" do
      # `import Stream, except: [filter: 2]` keeps `Stream.reject` in scope, so a bare swap of
      # `filter`→`reject` would be ambiguous. The whole `import Enum` resolves `filter`, but the
      # rebuild must qualify (not bare) so the swap names the real Enum.
      calls =
        resolved("""
        defmodule M do
          import Stream, except: [filter: 2]
          import Enum
          def f(xs, fun), do: filter(xs, fun)
        end
        """)

      assert calls[:filter] == {[:Enum], :qualify}
    end
  end

  describe "selective import (only/except — qualified rebuild)" do
    test "only: lists exact name/arity, resolving them (and only them)" do
      calls =
        resolved("""
        defmodule M do
          import Enum, only: [reject: 2]
          def f(xs), do: reject(xs, & &1)
        end
        """)

      assert calls[:reject] == {[:Enum], :qualify}
    end

    test "except: resolves the module's other exports, not the excepted ones" do
      calls =
        resolved("""
        defmodule M do
          import Enum, except: [reject: 2]
          def keep(xs), do: filter(xs, & &1)
          def gone(xs), do: reject(xs, & &1)
        end
        """)

      assert calls[:filter] == {[:Enum], :qualify}
      refute Map.has_key?(calls, :reject)
    end

    test "an ignored option (warn: false) leaves a whole import" do
      calls =
        resolved("""
        defmodule M do
          import Enum, warn: false
          def f(xs), do: reject(xs, & &1)
        end
        """)

      assert calls[:reject] == {[:Enum], :bare}
    end
  end

  describe "kind filters (only: :functions / :macros)" do
    test "only: :macros resolves a macro export, not a function of the same module" do
      calls =
        resolved("""
        defmodule M do
          import Integer, only: :macros
          def f(n) when is_even(n), do: gcd(n, 2)
        end
        """)

      assert calls[:is_even] == {[:Integer], :qualify}
      refute Map.has_key?(calls, :gcd)
    end

    test "only: :functions resolves a function export, not a macro" do
      calls =
        resolved("""
        defmodule M do
          import Integer, only: :functions
          def f(n) when is_even(n), do: gcd(n, 2)
        end
        """)

      assert calls[:gcd] == {[:Integer], :qualify}
      refute Map.has_key?(calls, :is_even)
    end
  end

  describe "import on an alias and re-import" do
    test "import of an aliased name resolves through the alias env to the real module" do
      calls =
        resolved("""
        defmodule M do
          alias Enum, as: E
          import E
          def f(xs), do: reject(xs, & &1)
        end
        """)

      assert calls[:reject] == {[:Enum], :bare}
    end

    test "alias and import interleave: an alias rebinds a later import's module" do
      # `import Enum` (the real Enum, captured here); then the *name* `Enum` is rebound to
      # `String`; then `import Enum` imports `String`. Both modules end up imported, so
      # `reject` resolves to the real Enum (String has none) and `split` to String (Enum.split
      # is /2). This only works because aliases and imports fold together, in source order.
      # Two imports are in scope, so the rebuild qualifies (a bare sibling could be ambiguous).
      calls =
        resolved("""
        defmodule M do
          import Enum
          alias String, as: Enum
          import Enum
          def a(xs), do: reject(xs, & &1)
          def b(s), do: split(s)
        end
        """)

      assert calls[:reject] == {[:Enum], :qualify}
      assert calls[:split] == {[:String], :qualify}
    end

    test "a later only: import of the same module replaces the earlier selection" do
      calls =
        resolved("""
        defmodule M do
          import Enum
          import Enum, only: [reject: 2]
          def kept(xs), do: reject(xs, & &1)
          def narrowed(xs), do: map(xs, & &1)
        end
        """)

      assert calls[:reject] == {[:Enum], :qualify}
      refute Map.has_key?(calls, :map)
    end

    test "a later except: subtracts from the prior selection, not from all" do
      # `only [reject, sort]` then `except [reject]` leaves only `sort` — so `reject` is gone
      # *and* `filter` (never in the `only`) must NOT be treated as imported. (The old
      # all-minus-except model would wrongly have resolved `filter` to Enum.)
      calls =
        resolved("""
        defmodule M do
          import Enum, only: [reject: 2, sort: 1]
          import Enum, except: [reject: 2]
          def a(xs), do: sort(xs)
          def b(xs, g), do: reject(xs, g)
          def c(xs, g), do: filter(xs, g)
        end
        """)

      assert calls[:sort] == {[:Enum], :qualify}
      refute Map.has_key?(calls, :reject)
      refute Map.has_key?(calls, :filter)
    end

    test "a later except: of a whole import subtracts (the common all-but-X idiom)" do
      calls =
        resolved("""
        defmodule M do
          import Enum
          import Enum, except: [filter: 2]
          def a(xs, g), do: reject(xs, g)
          def b(xs, g), do: filter(xs, g)
        end
        """)

      assert calls[:reject] == {[:Enum], :qualify}
      refute Map.has_key?(calls, :filter)
    end
  end

  describe "per-arity resolution" do
    test "only: resolves the listed arity but not a different one" do
      calls =
        resolved("""
        defmodule M do
          import Enum, only: [reject: 2]
          def two(xs), do: reject(xs, & &1)
        end
        """)

      assert calls[:reject] == {[:Enum], :qualify}

      none =
        resolved("""
        defmodule M do
          import Enum, only: [reject: 2]
          def one(xs), do: reject(xs)
        end
        """)

      refute Map.has_key?(none, :reject)
    end

    test "a piped bare call resolves at its effective (one-higher) arity" do
      calls =
        resolved("""
        defmodule M do
          import Enum, only: [reject: 2]
          def f(xs), do: xs |> reject(& &1)
        end
        """)

      assert calls[:reject] == {[:Enum], :qualify}
    end
  end

  describe "lexical scoping" do
    test "an import is textual: it applies only to calls after it" do
      calls =
        resolved("""
        defmodule M do
          def a(xs), do: reject(xs, & &1)
          import Enum
          def b(xs), do: filter(xs, & &1)
        end
        """)

      refute Map.has_key?(calls, :reject)
      assert calls[:filter] == {[:Enum], :bare}
    end

    test "a nested module inherits the enclosing imports" do
      calls =
        resolved("""
        defmodule Outer do
          import Enum
          defmodule Inner do
            def f(xs), do: reject(xs, & &1)
          end
        end
        """)

      assert calls[:reject] == {[:Enum], :bare}
    end

    test "an import inside a nested module does not leak to the outer scope" do
      calls =
        resolved("""
        defmodule Outer do
          defmodule Inner do
            import Enum
          end

          def f(xs), do: reject(xs, & &1)
        end
        """)

      refute Map.has_key?(calls, :reject)
    end

    test "an import inside a function body scopes to the rest of that body" do
      calls =
        resolved("""
        defmodule M do
          def go(xs) do
            import Enum
            reject(xs, & &1)
          end
        end
        """)

      assert calls[:reject] == {[:Enum], :bare}
    end
  end

  describe "Erlang atom-module imports" do
    test "a whole import of an atom module resolves a bare call to the atom (bare rebuild)" do
      calls =
        resolved("""
        defmodule M do
          import :binary
          def f(x), do: split(x, ",")
        end
        """)

      assert calls[:split] == {:binary, :bare}
    end

    test "a selective import of an atom module resolves the listed call (qualified rebuild)" do
      calls =
        resolved("""
        defmodule M do
          import :binary, only: [split: 2]
          def f(x), do: split(x, ",")
        end
        """)

      assert calls[:split] == {:binary, :qualify}
    end
  end

  describe "Kernel displacement" do
    test "a Kernel function excepted from Kernel is marked displaced" do
      calls =
        resolved("""
        defmodule M do
          import Kernel, except: [abs: 1]
          import MyAbs
          def f(x), do: abs(x)
        end
        """)

      assert calls[:abs] == :kernel_displaced
    end

    test "a plain Kernel call is neither resolved nor displaced" do
      calls =
        resolved("""
        defmodule M do
          def f(a, b), do: min(abs(a), b)
        end
        """)

      refute Map.has_key?(calls, :min)
      refute Map.has_key?(calls, :abs)
    end
  end
end
