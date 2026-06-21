defmodule Mutare.GuardDropTest do
  @moduledoc """
  `Mutare.Mutators.GuardDrop` removes a clause's whole `when` guard, broadening it
  to match unconditionally — but only for an *inert* guard no other family already
  mutates, so it never piles a redundant mutant on a guard that is already covered.
  Exercised across all four guarded-clause positions (`def`/`defp` heads, `case`,
  `receive`, `fn`) for discovery, compilation, and runtime behaviour.
  """
  use ExUnit.Case, async: false

  alias Mutare.{Report, Selector, Site}

  defp sites(src, opts \\ []) do
    {meta, sites, _} = Mutare.transform_string(src, Keyword.merge([file: "g.ex"], opts))
    {meta, sites}
  end

  defp guard_drops(src, opts \\ []) do
    {_meta, sites} = sites(src, opts)
    Enum.filter(sites, &(&1.mutator == :guard_drop))
  end

  describe "the incidentally-covered dedup rule" do
    test "an inert guard (a bare type predicate) is removed" do
      gd =
        guard_drops("""
        defmodule M do
          def f(x) when is_binary(x), do: :s
          def f(_), do: :o
        end
        """)

      assert [%Site{mutator: :guard_drop, kind: :lifted}] = gd
    end

    test "a guard a swap family already mutates is left alone (Integer.is_even)" do
      assert guard_drops("""
             defmodule M do
               require Integer
               def f(x) when Integer.is_even(x), do: :e
               def f(_), do: :o
             end
             """) == []
    end

    test "a guard with a boolean operator is left alone (x > 0)" do
      assert guard_drops("""
             defmodule M do
               def f(x) when x > 0, do: :p
               def f(_), do: :o
             end
             """) == []
    end

    test "a conjunction is left alone (covered by Conditional/Logical/Relational)" do
      assert guard_drops("""
             defmodule M do
               def f(x) when is_binary(x) and byte_size(x) > 0, do: :s
               def f(_), do: :o
             end
             """) == []
    end

    test "the rule is relative to the enabled set: disabling Integer uncovers its guard" do
      src = """
      defmodule M do
        require Integer
        def f(x) when Integer.is_even(x), do: :e
        def f(_), do: :o
      end
      """

      # With Integer enabled the guard is covered; without it, GuardDrop is the only signal.
      without_integer = Mutare.Mutators.all() -- [Mutare.Mutators.Integer]
      assert [%Site{mutator: :guard_drop}] = guard_drops(src, mutators: without_integer)
    end

    test "the family is off when not enabled" do
      assert guard_drops(
               """
               defmodule M do
                 def f(x) when is_binary(x), do: :s
                 def f(_), do: :o
               end
               """,
               mutators: [Mutare.Mutators.Relational]
             ) == []
    end

    test "a single-clause function is lifted solely to carry its guard removal" do
      {meta, gd} =
        {elem(sites("defmodule M do\n  def f(x) when is_atom(x), do: :a\nend\n"), 0),
         guard_drops("defmodule M do\n  def f(x) when is_atom(x), do: :a\nend\n")}

      assert [%Site{mutator: :guard_drop, kind: :lifted}] = gd
      assert meta =~ "def f(mutare_arg1) do"
      assert {:ok, _} = Code.string_to_quoted(meta)
    end
  end

  describe "every guarded-clause position" do
    test "case clause guard is removed in place" do
      gd =
        guard_drops("""
        defmodule M do
          def g(v) do
            case v do
              x when is_binary(x) -> {:s, x}
              _ -> :o
            end
          end
        end
        """)

      assert [%Site{mutator: :guard_drop, kind: :in_place} = s] = gd
      assert s.original_code == "x when is_binary(x)"
      assert s.mutated_code == "x"
    end

    test "receive clause guard is removed in place" do
      gd =
        guard_drops("""
        defmodule M do
          def r do
            receive do
              x when is_atom(x) -> :a
              _ -> :o
            end
          end
        end
        """)

      assert [%Site{mutator: :guard_drop, kind: :in_place}] = gd
    end

    test "a single-pattern fn clause guard is removed in place" do
      gd =
        guard_drops("""
        defmodule M do
          def h, do: fn x when is_integer(x) -> :i; _ -> :o end
        end
        """)

      assert [%Site{mutator: :guard_drop, kind: :in_place}] = gd
    end

    test "a multi-pattern fn clause is skipped (no single rangeable when head)" do
      assert guard_drops("""
             defmodule M do
               def h, do: fn x, y when is_atom(x) -> {x, y}; a, b -> {a, b} end
             end
             """) == []
    end
  end

  describe "the head is left exactly as written (never masked)" do
    test "a guard-only variable that becomes unused still compiles (the warning is harmless)" do
      # `x` is read only by the guard; once it is dropped, `x` is unused and the mutant
      # clause warns. We deliberately do NOT rename it to `_`: a macro in the body can read
      # a bound variable by name (`binding/0,1`, or any custom macro that captures the
      # caller's bindings), undetectably from the source, so renaming could silently change
      # behaviour. The warning is accepted; the metamutant must still compile (warnings do
      # not fail compilation). Covers the def-head, `case`, and `receive` positions.
      for src <- [
            "defmodule GDc1 do\n  def f(x) when is_binary(x), do: :s\n  def f(_), do: :o\nend\n",
            "defmodule GDc2 do\n  def g(v), do: (case v do x when is_atom(x) -> :a; _ -> :o end)\nend\n",
            "defmodule GDc3 do\n  def r do\n    receive do\n      x when is_atom(x) -> :a\n    end\n  end\nend\n"
          ] do
        {meta, _} = sites(src)
        {mods, _io} = ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)
        assert is_list(mods) and mods != [], "metamutant failed to compile:\n#{meta}"
      end
    end

    test "the survivor diff keeps the original variable in both head and mutant" do
      [s] =
        guard_drops(
          "defmodule M do\n  def f(x) when is_binary(x), do: :s\n  def f(_), do: :o\nend\n"
        )

      diff =
        Report.survivor(
          s,
          "defmodule M do\n  def f(x) when is_binary(x), do: :s\n  def f(_), do: :o\nend\n"
        )

      assert diff =~ "- "
      assert diff =~ "def f(x) when is_binary(x), do: :s"
      # The mutant keeps `x` (unchanged head) — not `_`.
      assert diff =~ "+  def f(x), do: :s"
    end
  end

  describe "end-to-end: lift, compile once, switch at runtime" do
    setup do
      Selector.put(Selector.baseline())
      on_exit(fn -> Selector.put(Selector.baseline()) end)
      :ok
    end

    test "removing a def-head guard broadens the clause" do
      src = """
      defmodule GuardDropRuntimeDef do
        def f(x) when is_binary(x), do: :string
        def f(_), do: :other
      end
      """

      {meta, all} = sites(src)
      [{mod, _}] = Code.compile_string(meta)
      [gd] = Enum.filter(all, &(&1.mutator == :guard_drop))

      # Baseline: a non-binary falls through to the catch-all.
      assert mod.f("a") == :string
      assert mod.f(1) == :other

      # Guard removed: the first clause now matches the integer too.
      Selector.put(gd.id)
      assert mod.f(1) == :string
      assert mod.f("a") == :string
    end

    test "a broadened head with an existing _name binding matches differing arguments" do
      # The head is left exactly as written — `f(x, _x)` — so the broadened clause matches
      # differing arguments. (A masking design that renamed the guard-only `x` to `_x` would
      # have wrongly produced `f(_x, _x)`, matching only *equal* arguments — one reason we
      # never rewrite the head.)
      src = """
      defmodule GuardDropRuntimeCollide do
        def f(x, _x) when is_atom(x), do: :atom
        def f(_, _), do: :other
      end
      """

      {meta, all} = sites(src)
      [{mod, _}] = Code.compile_string(meta)
      [gd] = Enum.filter(all, &(&1.mutator == :guard_drop))

      # Baseline: a non-atom first argument falls through to the catch-all.
      assert mod.f(1, 2) == :other

      # Guard removed: the broadened clause matches even though the two arguments differ.
      Selector.put(gd.id)
      assert mod.f(1, 2) == :atom
    end

    test "a guard-only variable read by binding() in the body keeps its name" do
      # The whole reason we never mask: `binding/0,1` (and any custom macro) reads bound
      # variables *by name*, with no syntactic mention the transform could detect. Renaming
      # the guard-only `x` to `_` would silently drop it from `binding()`'s result. Leaving
      # the name keeps it observable.
      src = """
      defmodule GuardDropRuntimeBinding do
        def f(x) when is_atom(x), do: Keyword.get(binding(), :x)
        def f(_), do: :other
      end
      """

      {meta, all} = sites(src)
      [{mod, _}] = Code.compile_string(meta)
      [gd] = Enum.filter(all, &(&1.mutator == :guard_drop))

      # Baseline: binding() reflects the named parameter back.
      assert mod.f(:a) == :a

      # Guard removed: the broadened clause matches a non-atom, and binding() STILL sees `x`
      # by name. Masking `x` to `_` would make this `nil`.
      Selector.put(gd.id)
      assert mod.f(1) == 1
    end

    test "removing a case-clause guard broadens that clause" do
      src = """
      defmodule GuardDropRuntimeCase do
        def g(v) do
          case v do
            x when is_binary(x) -> {:s, x}
            _ -> :o
          end
        end
      end
      """

      {meta, all} = sites(src)
      [{mod, _}] = Code.compile_string(meta)
      [gd] = Enum.filter(all, &(&1.mutator == :guard_drop))

      assert mod.g(1) == :o

      Selector.put(gd.id)
      assert mod.g(1) == {:s, 1}
    end
  end
end
