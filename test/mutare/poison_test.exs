defmodule Mutare.PoisonTest do
  @moduledoc "Compile-poisoning: detect the offending mutant, drop it, recover."
  use ExUnit.Case, async: true

  alias Mutare.Poison

  @poison [mutators: [Mutare.Test.PoisonMutator], file: "lib/p.ex"]
  @src "defmodule P do\n  def f(a, b), do: a + b\nend\n"

  describe "transform :skip_ids" do
    test "a skipped id is recorded :poisoned with no selector, so it compiles" do
      %{metamutant: meta, sites: [site]} =
        Mutare.Transform.transform_string_with_sites(@src, @poison)

      # Without skipping, the poison mutant is in the metamutant (won't compile).
      assert meta =~ "mutare_unbound_xyz"

      %{metamutant: meta2, sites: [site2]} =
        Mutare.Transform.transform_string_with_sites(
          @src,
          Keyword.put(@poison, :skip_ids, MapSet.new([site.id]))
        )

      assert site2.id == site.id
      assert site2.poisoned
      refute meta2 =~ "mutare_unbound_xyz"
      # And it actually compiles now.
      assert [{P, _}] = Mutare.Test.Compile.string(meta2)
    after
      :code.purge(P)
      :code.delete(P)
    end
  end

  describe "Poison.ids/4" do
    test "maps a compile error's file:line to the mutant whose generated code spans it" do
      %{metamutant: meta, sites: [site], dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(@src, @poison)

      line =
        meta
        |> String.split("\n")
        |> Enum.find_index(&(&1 =~ "mutare_unbound_xyz"))
        |> Kernel.+(1)

      error = "lib/p.ex:#{line}:5: undefined variable \"mutare_unbound_xyz\""
      # `Poison.ids/4` takes the metamutant *sources* (plus each file's dispatch variable)
      # and builds the manifest lazily, so the scan never pays for it on a healthy run.
      metamutants = %{"lib/p.ex" => meta}
      assert Poison.ids(error, metamutants, %{"lib/p.ex" => var}) == MapSet.new([site.id])
    end

    test "returns empty when nothing maps (caller then aborts)" do
      assert Poison.ids("some unrelated error", %{}, %{}) == MapSet.new()
    end

    test "memoizes the per-file manifest and ignores an error in an untracked file" do
      # Two distinct error lines in the *same* tracked file (the second resolved from the
      # memoized manifest, not a re-parse) plus an error in a file absent from `metamutants`
      # (no manifest → contributes nothing). Exercises the cache-hit and missing-file paths.
      %{metamutant: meta, sites: [site], dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(@src, @poison)

      poison_line =
        meta
        |> String.split("\n")
        |> Enum.find_index(&(&1 =~ "mutare_unbound_xyz"))
        |> Kernel.+(1)

      error =
        "lib/p.ex:#{poison_line}:5: undefined variable \"mutare_unbound_xyz\"\n" <>
          "lib/p.ex:9999:1: some other error\n" <>
          "lib/untracked.ex:3:1: undefined variable \"q\"\n"

      assert Poison.ids(error, %{"lib/p.ex" => meta}, %{"lib/p.ex" => var}) ==
               MapSet.new([site.id])
    end

    test "ignores a warning's file:line — only error diagnostics locate poison" do
      %{metamutant: meta, sites: [site], dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(@src, @poison)

      metamutants = %{"lib/p.ex" => meta}
      vars = %{"lib/p.ex" => var}

      line =
        meta
        |> String.split("\n")
        |> Enum.find_index(&(&1 =~ "mutare_unbound_xyz"))
        |> Kernel.+(1)

      # mix footers a *warning* with the same `└─ file:line` shape as an error. A failed
      # compile prints every warning the mutations provoke; pointing one at the mutant's
      # own line must NOT flag it as poison (the bug that dropped ~110 valid plug mutants).
      warning =
        "    warning: variable \"x\" is unused\n" <>
          "    └─ lib/p.ex:#{line}:5: P.f/2\n"

      assert Poison.ids(warning, metamutants, vars) == MapSet.new()

      # The same location inside an `error:` diagnostic *is* the poison.
      error =
        "    error: undefined variable \"mutare_unbound_xyz\"\n" <>
          "    └─ lib/p.ex:#{line}:5: P.f/2\n"

      assert Poison.ids(error, metamutants, vars) == MapSet.new([site.id])

      # A warning sharing the output with the real error neither adds nor hides ids.
      assert Poison.ids(warning <> error, metamutants, vars) == MapSet.new([site.id])
    end
  end

  describe "macro_poison/4 (macro-expansion fallback, metamutant space)" do
    # Transform a source into `{%{file => metamutant}, %{file => dispatch_var}, sites}` — the
    # real rendered metamutant the fallback attributes against (not the original), so its
    # manifest carries every id.
    defp transform(src, mutators), do: transform_at("lib/r.ex", src, mutators)

    defp transform_at(file, src, mutators) do
      %{metamutant: meta, sites: sites, dispatch_var: var} =
        Mutare.Transform.transform_string_with_sites(src, file: file, mutators: mutators)

      {%{file => meta}, %{file => var}, sites}
    end

    defp frame(output_line),
      do: "** (RuntimeError) nope\n    #{output_line}\n    lib/r.ex:2: R.f/4\n"

    test "attributes the mutants inside the blamed macro's call, not siblings outside" do
      src = """
      defmodule R do
        def f(a, b, c, d) do
          x = query(a > b)
          y = c > d
          {x, y}
        end
      end
      """

      {metamutants, vars, sites} = transform(src, [Mutare.Mutators.Relational])
      inside = for s <- sites, s.line == 3, do: s.id
      outside = for s <- sites, s.line == 4, do: s.id
      assert inside != [] and outside != []

      assert [{{"MyDsl", :query}, ids}] =
               Mutare.Poison.macro_poison(
                 frame("expanding macro: MyDsl.query/1"),
                 metamutants,
                 vars
               )

      assert ids == MapSet.new(inside)
      refute Enum.any?(outside, &MapSet.member?(ids, &1))
    end

    test "attributes a mutation in the piped value of `lhs |> macro()`" do
      # After pipe expansion the LHS is the macro's first argument, but its selector renders on
      # the pipe's *left* — before the RHS `query()` node. The whole `|>` must be ranged, or the
      # poison maps to nothing and the run aborts.
      src = """
      defmodule R do
        def f(a, b) do
          (a > b) |> query()
        end
      end
      """

      {metamutants, vars, sites} = transform(src, [Mutare.Mutators.Relational])
      assert sites != []
      expected = MapSet.new(sites, & &1.id)

      assert [{{"MyDsl", :query}, ^expected}] =
               Mutare.Poison.macro_poison(
                 frame("expanding macro: MyDsl.query/1"),
                 metamutants,
                 vars
               )
    end

    test "spans a macro-argument literal on its own line (true call range, not child metadata)" do
      # The `1` has no `:line` metadata; the fallback must reach the closing paren to span it.
      src = """
      defmodule R do
        def f do
          query(
            1
          )
        end
      end
      """

      {metamutants, vars, sites} = transform(src, [Mutare.Mutators.IntegerLiteral])
      assert sites != []
      expected = MapSet.new(sites, & &1.id)

      assert [{{"MyDsl", :query}, ^expected}] =
               Mutare.Poison.macro_poison(
                 frame("expanding macro: MyDsl.query/1"),
                 metamutants,
                 vars
               )
    end

    test "returns [] when the blamed macro name matches no call in the metamutant" do
      {metamutants, vars, _sites} =
        transform("defmodule R do\n  def f(a, b), do: query(a > b)\nend\n", [
          Mutare.Mutators.Relational
        ])

      assert Mutare.Poison.macro_poison(
               frame("expanding macro: Other.absent/2"),
               metamutants,
               vars
             ) ==
               []
    end

    test "returns [] when the output names no expanding macro" do
      {metamutants, vars, _sites} =
        transform("defmodule R do\n  def f(a, b), do: query(a > b)\nend\n", [
          Mutare.Mutators.Relational
        ])

      assert Mutare.Poison.macro_poison("just an ordinary error", metamutants, vars) == []
    end

    test "ignores a definition head that shares the blamed macro's name" do
      # `def query(a \\ (1 > 2))` parses exactly like a `query(...)` call; its default-arg
      # mutation must NOT be attributed to the macro. Only the real `MyDsl.query(...)` counts.
      src = ~S"""
      defmodule R do
        def query(a \\ (1 > 2)) do
          a
        end

        def use_it(p, q) do
          MyDsl.query(p > q)
        end
      end
      """

      {metamutants, vars, sites} = transform(src, [Mutare.Mutators.Relational])
      head_ids = for s <- sites, s.line == 2, do: s.id
      call_ids = for s <- sites, s.line == 7, do: s.id
      assert head_ids != [] and call_ids != []

      assert [{{"MyDsl", :query}, ids}] =
               Mutare.Poison.macro_poison(
                 frame("expanding macro: MyDsl.query/1"),
                 metamutants,
                 vars
               )

      assert ids == MapSet.new(call_ids)
      refute Enum.any?(head_ids, &MapSet.member?(ids, &1))
    end

    test "finds a real macro call inside a def-head default argument" do
      # `def limit(n \\ Size.megabytes(5))`: the head's *call shape* is skipped, but its default
      # expression must still be searched — the `megabytes(5)` there poisons expansion too, and
      # dropping only the outer head (not the whole head) is what keeps it reachable.
      src = ~S"""
      defmodule R do
        def limit(n \\ Size.megabytes(5)) do
          n
        end
      end
      """

      {metamutants, vars, sites} = transform(src, [Mutare.Mutators.IntegerLiteral])
      assert sites != []
      expected = MapSet.new(sites, & &1.id)

      assert [{{"Size", :megabytes}, ^expected}] =
               Mutare.Poison.macro_poison(
                 frame("expanding macro: Size.megabytes/1"),
                 metamutants,
                 vars
               )
    end

    test "scans only the macro's call-site file, not its implementation frames" do
      # A macro defined in the target project puts frames from its *implementation* file on the
      # stack, BEFORE the `expanding macro:` marker; a same-named call there must not be swept
      # in. Here the only `query(...)` call lives in the impl file — so if it were scanned we'd
      # get its ids, but the call-site file (`lib/r.ex`, post-marker) has none.
      {%{"lib/r.ex" => call_meta}, %{"lib/r.ex" => call_var}, _} =
        transform_at("lib/r.ex", "defmodule R do\n  def f(a, b), do: a + b\nend\n", [
          Mutare.Mutators.Arithmetic
        ])

      {%{"lib/my_dsl.ex" => impl_meta}, %{"lib/my_dsl.ex" => impl_var}, impl_sites} =
        transform_at(
          "lib/my_dsl.ex",
          "defmodule MyDsl do\n  defmacro query(e), do: e\n  def other(c, d), do: query(c > d)\nend\n",
          [Mutare.Mutators.Relational]
        )

      assert impl_sites != []
      metamutants = %{"lib/r.ex" => call_meta, "lib/my_dsl.ex" => impl_meta}
      vars = %{"lib/r.ex" => call_var, "lib/my_dsl.ex" => impl_var}

      # Impl frame (pre-marker) then the call site (`lib/r.ex`, post-marker).
      output =
        "** (RuntimeError) boom\n" <>
          "    lib/my_dsl.ex:3: MyDsl.\"MACRO-query\"/2\n" <>
          "    expanding macro: MyDsl.query/1\n" <>
          "    lib/r.ex:2: R.f/2\n"

      assert Mutare.Poison.macro_poison(output, metamutants, vars) == []
    end
  end
end
