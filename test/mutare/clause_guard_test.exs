defmodule Mutare.ClauseGuardTest do
  @moduledoc """
  Guard-only mutation of the clauses no clause-list delivery can reach: a `with`/`for` `<-`
  clause, a `with`/`try` `else` clause, a `try` `catch` clause, and a `for … reduce:` `do`
  clause. `Mutare.Transform.ClauseGuardEmit` rewrites each such guard into a gated guard
  *sequence* in place (`pattern when active === id and mutant when … when active ∉ ids and
  original`) — the pattern is untouched, so no extra clause is needed. Exercised for
  discovery, compilation, runtime switching, poison attribution, and the unbound-scope
  refusal.
  """
  use ExUnit.Case, async: false

  alias Mutare.{Manifest, Selector, Site}

  defp sites(src, opts \\ []) do
    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(src, Keyword.merge([file: "cg.ex"], opts))

    {meta, sites}
  end

  defp guard_sites(sites), do: Enum.filter(sites, &(&1.mutator in [:relational, :guard_drop]))

  defp site(sites, original, mutated),
    do: Enum.find(sites, &(&1.original_code == original and &1.mutated_code == mutated))

  describe "discovery: each position offers its guard the same swaps a case clause gets" do
    test "a `with` `<-` clause guard" do
      {meta, all} =
        sites("""
        defmodule M do
          def f(x), do: with(v when v > 0 <- x, do: v, else: (_ -> 0))
        end
        """)

      assert [%Site{mutator: :relational, kind: :in_place, line: 2} | _] = guard_sites(all)
      assert site(all, "v > 0", "v >= 0")
      assert site(all, "v > 0", "v < 0")
      assert_compiles(meta)
    end

    test "a `with` `else` clause guard, and its inert guard's GuardDrop" do
      {meta, all} =
        sites("""
        defmodule M do
          def f(x) do
            with {:ok, v} <- x do
              v
            else
              e when e > 0 -> e
              e when is_atom(e) -> :atom
              _ -> 0
            end
          end
        end
        """)

      assert site(all, "e > 0", "e >= 0").line == 6
      assert %Site{mutator: :guard_drop, line: 7} = site(all, "e when is_atom(e)", "e")
      assert_compiles(meta)
    end

    test "a `try` `catch` clause guard (a two-pattern head: swaps, but no GuardDrop)" do
      {meta, all} =
        sites("""
        defmodule M do
          def f(x) do
            try do
              throw(x)
            catch
              :throw, v when v > 0 -> v
              :throw, v when is_atom(v) -> :atom
              :throw, _ -> 0
            end
          end
        end
        """)

      assert site(all, "v > 0", "v >= 0").line == 6
      # `catch kind, reason when …` has no single `{:when, pattern, guard}` node to diff — the
      # same skip `fn x, y when … ->` documents.
      refute Enum.any?(all, &(&1.mutator == :guard_drop))
      assert_compiles(meta)
    end

    test "a `try` `else` clause guard" do
      {meta, all} =
        sites("""
        defmodule M do
          def f(x) do
            try do
              x
            else
              v when v > 0 -> v
              _ -> 0
            end
          end
        end
        """)

      assert site(all, "v > 0", "v >= 0").line == 6
      assert_compiles(meta)
    end

    test "a `for` generator guard and a `reduce:` do-clause guard" do
      {meta, all} =
        sites("""
        defmodule M do
          def f(xs), do: for(v when v > 0 <- xs, do: v)

          def g(xs) do
            for v <- xs, reduce: 0 do
              acc when acc > 5 -> acc
              acc -> acc + v
            end
          end
        end
        """)

      assert site(all, "v > 0", "v >= 0").line == 2
      assert site(all, "acc > 5", "acc >= 5").line == 6
      assert_compiles(meta)
    end

    test "the patterns beside the guard stay patterns (no literal or structural mutant)" do
      {meta, all} =
        sites("""
        defmodule M do
          def f(x), do: with({:ok, 1, v} when v > 0 <- x, do: v, else: (_ -> :e))
        end
        """)

      # A pattern-literal or wildcard mutant would need a clause of its own, which a `<-`
      # can't host — only the guard is offered: the pattern's `1` stays (in a `case` clause it
      # would be offered), while the guard's own `0` mutates as it does in any guard.
      refute Enum.any?(all, &(&1.original_code == "1"))
      refute Enum.any?(all, &(&1.mutator in [:pattern_wildcard, :pattern_swap]))
      assert site(all, "0", "1")
      assert site(all, "v > 0", "v >= 0")
      assert_compiles(meta)
    end
  end

  describe "end-to-end: compile once, switch the guard at runtime" do
    setup do
      Selector.put(Selector.baseline())
      on_exit(fn -> Selector.put(Selector.baseline()) end)
      :ok
    end

    test "a `with` `<-` guard mutant changes only its own clause; a non-match still reaches else" do
      {meta, all} =
        sites("""
        defmodule ClauseGuardWith do
          def f(x) do
            with v when v > 0 <- x do
              {:ok, v}
            else
              e when is_atom(e) -> {:atom, e}
              e -> {:other, e}
            end
          end
        end
        """)

      [{mod, _}] = Mutare.Test.Compile.string(meta)

      assert mod.f(0) == {:other, 0}
      assert mod.f(1) == {:ok, 1}
      assert mod.f(-1) == {:other, -1}

      # `v > 0` → `v >= 0`: zero now matches; the else path is otherwise as written.
      Selector.put(site(all, "v > 0", "v >= 0").id)
      assert mod.f(0) == {:ok, 0}
      assert mod.f(-1) == {:other, -1}

      # `v > 0` → `v < 0`: the non-matching value still flows to `else` unchanged.
      Selector.put(site(all, "v > 0", "v < 0").id)
      assert mod.f(1) == {:other, 1}
      assert mod.f(-1) == {:ok, -1}

      # The `else` guard dropped: the atom clause now takes anything.
      Selector.put(site(all, "e when is_atom(e)", "e").id)
      assert mod.f(-1) == {:atom, -1}
      assert mod.f(1) == {:ok, 1}
    end

    test "a `for` generator guard mutant filters differently" do
      {meta, all} =
        sites("""
        defmodule ClauseGuardFor do
          def f(xs), do: for(v when v > 0 <- xs, do: v)
        end
        """)

      [{mod, _}] = Mutare.Test.Compile.string(meta)
      assert mod.f([-1, 0, 1]) == [1]

      Selector.put(site(all, "v > 0", "v >= 0").id)
      assert mod.f([-1, 0, 1]) == [0, 1]
    end

    test "a `try` `catch` guard mutant re-routes the caught value" do
      {meta, all} =
        sites("""
        defmodule ClauseGuardCatch do
          def f(x) do
            try do
              throw(x)
            catch
              :throw, v when v > 0 -> {:pos, v}
              :throw, v -> {:rest, v}
            end
          end
        end
        """)

      [{mod, _}] = Mutare.Test.Compile.string(meta)
      assert mod.f(0) == {:rest, 0}

      Selector.put(site(all, "v > 0", "v >= 0").id)
      assert mod.f(0) == {:pos, 0}
    end

    test "a `reduce:` do-clause guard mutant changes the accumulation" do
      {meta, all} =
        sites("""
        defmodule ClauseGuardReduce do
          def f(xs) do
            for v <- xs, reduce: 0 do
              acc when acc > 5 -> acc
              acc -> acc + v
            end
          end
        end
        """)

      [{mod, _}] = Mutare.Test.Compile.string(meta)
      assert mod.f([5, 1]) == 6

      Selector.put(site(all, "acc > 5", "acc >= 5").id)
      assert mod.f([5, 1]) == 5
    end

    test "a raising mutant guard fails only its own alternative" do
      # `hd(v)` on a non-list raises inside a guard → that alternative is false, exactly as a
      # source guard `when hd(v) == 1` would be; the original alternative is not consulted
      # while the mutant is active, so the value flows to `else` as the mutant dictates.
      {meta, all} =
        sites(
          """
          defmodule ClauseGuardRaise do
            def f(x), do: with(v when hd(v) == 1 <- x, do: {:ok, v}, else: (e -> {:else, e}))
          end
          """,
          mutators: [Mutare.Mutators.Relational]
        )

      [{mod, _}] = Mutare.Test.Compile.string(meta)
      assert mod.f([1]) == {:ok, [1]}
      assert mod.f(:a) == {:else, :a}

      Selector.put(site(all, "hd(v) == 1", "hd(v) != 1").id)
      assert mod.f([1]) == {:else, [1]}
      assert mod.f([2]) == {:ok, [2]}
      assert mod.f(:a) == {:else, :a}
    end
  end

  describe "the scope gate" do
    test "outside a bound selector scope the guard candidates are not claimed" do
      # A `with` in a default-argument position runs in a generated head clause where no
      # `mutare_active` binding is in scope; a guard can't read `:persistent_term`, and there is
      # no whole-construct fallback (the clause's binding escapes) — so the guard is left alone,
      # with no id or site, and the metamutant compiles.
      {meta, all} =
        sites("""
        defmodule M do
          def f(x \\\\ with(v when v > 0 <- 1, do: v, else: (_ -> 0))), do: x
        end
        """)

      refute site(all, "v > 0", "v >= 0")
      assert_compiles(meta)
    end
  end

  describe "poison attribution" do
    test "a guard alternative's metamutant line maps to exactly its mutant" do
      source = """
      defmodule M do
        def f(x), do: with(v when v > 0 <- x, do: v, else: (_ -> 0))
      end
      """

      %{metamutant: meta, sites: all, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(source, file: "cg.ex")

      manifest = Manifest.from_source(meta, var)
      target = site(all, "v > 0", "v >= 0")

      line =
        meta
        |> String.split("\n")
        |> Enum.find_index(&String.contains?(&1, ~s[:erlang."=:="(mutare_active, #{target.id})]))
        |> Kernel.+(1)

      assert Manifest.ids_at_line(manifest, line) == [target.id]
    end
  end

  defp assert_compiles(meta) do
    assert [{_mod, _bin} | _] = Mutare.Test.Compile.string(meta)
  end
end
