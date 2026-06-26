defmodule Mutare.MacroPatternTest do
  @moduledoc """
  The structural pattern families (variable swap, duplicate→wildcard) also mutate the
  **pattern argument of a binding-escaping known macro** (`Kernel.destructure`, declared
  `:binding_pattern`, or a user-registered macro) when the call sits in a *value-discarded*
  position — a non-final statement of a block or a `with` clause. The macro binds variables
  that escape into the enclosing scope (exactly like a `=` match — indeed `destructure([x, y],
  v)` expands to `[x, y] = …`), so a selector `case` can't wrap the call; the bound variables
  are re-exported through a tuple and rebound outside (`{vars} = case <sel> do <id> ->
  macro(<mutated_pat>, …); {vars} … end`). Both the directly-written and piped forms route.
  Proven with one compile and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.{Report, Selector}

  @source """
  defmodule Mutare.MacroPatternFixture do
    def direct(v) do
      destructure([x, y], v)
      x - y
    end

    def qualified(v) do
      Kernel.destructure([x, y], v)
      x - y
    end

    def piped(v) do
      [a, b] |> destructure(v)
      a - b
    end

    def with_clause(input) do
      with {:ok, payload} <- input,
           destructure([p, q], payload) do
        p - q
      end
    end

    def for_filter(list) do
      for v <- list, destructure([m, n], v) do
        m - n
      end
    end

    def trailing(v) do
      destructure([x, y], v)
    end

    def repeated(v) do
      destructure([a, a], v)
      a
    end

    def value_arg(v) do
      destructure([x, y], Enum.reverse(v))
      x - y
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.MacroPatternFixture}

  setup_all do
    {metamutant, sites, _next_id} = Mutare.transform_string(@source, file: "mac.ex")

    # `trailing/1` returns the destructure value; `repeated/1`'s `[a, a]` self-constrains.
    # Any benign warning is captured so it does not clutter test output.
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      [{_module, _binary}] = Code.compile_string(metamutant)
    end)

    %{sites: sites, meta: metamutant}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  alias Mutare.MacroPatternFixture, as: F

  defp id(sites, mutator, mutated_code, line) do
    site =
      Enum.find(
        sites,
        &(&1.mutator == mutator and &1.mutated_code == mutated_code and &1.line == line)
      )

    assert site, "no #{mutator} site #{inspect(mutated_code)} on line #{line}"
    site.id
  end

  test "macro-pattern mutants are delivered in place (not lifted)", %{sites: sites, meta: meta} do
    refute meta =~ "__mutare_direct"
    refute meta =~ "__mutare_piped"

    structural = Enum.filter(sites, &(&1.mutator in [:pattern_swap, :pattern_wildcard]))
    assert structural != []
    assert Enum.all?(structural, &(&1.kind == :in_place))
  end

  test "baseline behaves like the original" do
    assert F.direct([5, 2]) == 3
    assert F.qualified([5, 2]) == 3
    assert F.piped([7, 2]) == 5
    assert F.with_clause({:ok, [9, 4]}) == 5
    assert F.with_clause(:error) == :error
    assert F.for_filter([[5, 2], [9, 3]]) == [3, 6]
    assert F.trailing([1, 2]) == [1, 2]
    assert F.repeated([7, 7]) == 7
    assert F.value_arg([2, 5]) == 3
  end

  describe "directly written destructure" do
    test "swapping the pattern binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "[y, x]", 3))
      assert F.direct([5, 2]) == 2 - 5
    end

    test "the swapped binding escapes to the rest of the scope", %{sites: sites} do
      # The export tuple rebinds x/y outside the selector, so `x - y` sees the swapped
      # values rather than an unbound variable.
      Selector.put(id(sites, :pattern_swap, "[y, x]", 3))
      assert is_integer(F.direct([1, 9]))
    end

    test "a Kernel-qualified call routes the same way", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "[y, x]", 8))
      assert F.qualified([5, 2]) == 2 - 5
    end
  end

  describe "piped destructure (pattern is the |> LHS)" do
    test "swapping the piped pattern binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "[b, a]", 13))
      assert F.piped([7, 2]) == 2 - 7
    end
  end

  describe "with-clause destructure" do
    test "swapping a `with` destructure clause's pattern is mutated", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "[q, p]", 19))
      assert F.with_clause({:ok, [7, 2]}) == 2 - 7
    end
  end

  describe "duplicate → wildcard drops the equality constraint" do
    test "thinning one occurrence binds either element (two mutants)", %{sites: sites} do
      first = id(sites, :pattern_wildcard, "[_, a]", 35)
      second = id(sites, :pattern_wildcard, "[a, _]", 35)
      refute first == second

      # baseline `[a, a] = v` requires equal elements (raises on [1, 2]); the wildcard
      # drops that, so an unequal list no longer raises and binds one element.
      Selector.put(first)
      assert F.repeated([1, 2]) == 2

      Selector.put(second)
      assert F.repeated([1, 2]) == 1
    end

    test "never wildcards both occurrences (thin mode, binding preserved)", %{sites: sites} do
      refute Enum.any?(sites, &(&1.mutator == :pattern_wildcard and &1.mutated_code == "[_, _]"))
    end
  end

  describe "position: only value-discarded statements/clauses are rewritten" do
    test "a `for` qualifier (a filter, not value-discarded) is never rewritten", %{sites: sites} do
      refute Enum.any?(
               sites,
               &(&1.line == 25 and &1.mutator in [:pattern_swap, :pattern_wildcard])
             )

      # the baseline for/filter still runs untouched
      assert F.for_filter([[5, 2], [9, 3]]) == [3, 6]
    end

    test "a trailing (final-statement) destructure is not rewritten", %{sites: sites} do
      refute Enum.any?(
               sites,
               &(&1.line == 31 and &1.mutator in [:pattern_swap, :pattern_wildcard])
             )
    end
  end

  test "a mutation in the value arg still fires (baseline branch)", %{sites: sites} do
    # `destructure([x, y], Enum.reverse(v))` — the `Enum.reverse` lives on the selector
    # catch-all's *emitted* value arg, so a CallRemoval mutant there fires when its
    # (non-pattern) id is active and the macro-pattern selector takes its baseline branch.
    site = Enum.find(sites, &(&1.mutator == :call_removal and &1.line == 40))
    assert site, "expected a call_removal site on the value arg"
    Selector.put(site.id)
    # removing `Enum.reverse` leaves `v`: destructure([x, y], v) on [2, 5] → x=2, y=5 → -3
    assert F.value_arg([2, 5]) == 2 - 5
  end

  test "an unknown id falls through to every original destructure", %{sites: sites} do
    _ = sites
    Selector.put(987_654)
    assert F.direct([5, 2]) == 3
    assert F.piped([7, 2]) == 5
    assert F.with_clause({:ok, [9, 4]}) == 5
  end

  test "renders a macro-pattern swap as a focused one-line diff", %{sites: sites} do
    site = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 3))

    assert Report.header(site) == "mac.ex:3  [pattern_swap, in-place]  SURVIVED"

    assert Report.diff(site, @source) ==
             "-    destructure([x, y], v)\n+    destructure([y, x], v)"
  end

  describe "user opt-in: a registered :binding_pattern macro" do
    # A user macro (`Mutare.Test.QueryDSL.unpack/2`) that binds its pattern into the
    # enclosing scope (it expands to `pattern = value`), registered `:binding_pattern` via
    # the declarative `:macros` option — exactly how a library exposes a destructure-like
    # macro. The transform must route its pattern arg like `Kernel.destructure`'s.
    @user_source """
    defmodule Mutare.UserUnpackFixture do
      import Mutare.Test.QueryDSL

      def go(v) do
        unpack([x, y], v)
        x - y
      end
    end
    """

    @compile {:no_warn_undefined, Mutare.UserUnpackFixture}

    setup do
      {meta, sites, _next} =
        Mutare.transform_string(@user_source,
          file: "user.ex",
          macros: [{Mutare.Test.QueryDSL, :unpack, 2, [:binding_pattern, :expression]}]
        )

      # Recompiled per test (the fixture is redefined) — capture the benign warning.
      {[{mod, _}], _io} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)

      %{mod: mod, sites: sites}
    end

    test "earns the structural swap mutant, delivered in place", %{sites: sites} do
      site = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 5))
      assert site
      assert site.kind == :in_place
      assert site.mutated_code == "[y, x]"
    end

    test "the swap binds the other value and escapes", %{mod: mod, sites: sites} do
      site = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 5))

      Selector.put(Selector.baseline())
      assert mod.go([5, 2]) == 3

      Selector.put(site.id)
      assert mod.go([5, 2]) == 2 - 5
    end
  end

  describe "a whole-call mutation coexists with the pattern mutants (direct form)" do
    # A custom mutator (`Mutare.Test.UnpackMutator`) that registers `unpack/2` and *also*
    # mutates the whole call. The pattern `[x, y]` earns a `:pattern_swap` mutant, and the
    # call earns the mutator's whole-call mutant. Both target the same binding-escaping call,
    # so they must be delivered together through the one tuple-export selector — the whole-call
    # mutant must not be silently dropped (it was shadowed by the prepended `:mutare`).
    @source """
    defmodule Mutare.WholeCallDirectFixture do
      import Mutare.Test.QueryDSL

      def go(v) do
        unpack([x, y], v)
        x - y
      end
    end
    """

    @compile {:no_warn_undefined, Mutare.WholeCallDirectFixture}

    setup do
      {meta, sites, _next} =
        Mutare.transform_string(@source,
          file: "whole.ex",
          mutators: [Mutare.Mutators.PatternSwap, Mutare.Test.UnpackMutator]
        )

      {[{mod, _}], _io} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)

      %{mod: mod, sites: sites}
    end

    test "both the pattern-swap and the whole-call mutant get a site", %{sites: sites} do
      assert Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 5))
      # The whole-call mutant — silently dropped before the fix — now exists.
      assert Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))
    end

    test "the whole-call mutant's note rides through the re-home onto the Site", %{sites: sites} do
      # The `:unpack_call` mutant is built by re-homing the call's `Candidate.InPlace` into a
      # `Candidate.MacroPattern`; its `%Mutation{}` note must survive that hop (it was dropped
      # when `MacroPattern` carried no `note` field). The pattern-swap mutant is noteless.
      call = Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))
      swap = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 5))
      assert call.note == "whole-call mutant — bindings still escape"
      assert swap.note == nil
    end

    test "each mutant switches independently and the bindings escape", %{mod: mod, sites: sites} do
      swap = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 5))
      call = Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))

      Selector.put(Selector.baseline())
      assert mod.go([5, 2]) == 3

      # `[y, x] = v` → y = 5, x = 2.
      Selector.put(swap.id)
      assert mod.go([5, 2]) == 2 - 5

      # `[x, y] = [9, 9]` → x = y = 9.
      Selector.put(call.id)
      assert mod.go([5, 2]) == 0
    end
  end

  describe "a whole-call mutation coexists with the pattern mutants (piped form)" do
    # The piped twin of the above. The stage `unpack(v)` carries the whole-call mutation on the
    # `|>` RHS child; if it were emitted as its own selector, this site's baseline would become
    # the illegal `[x, y] |> case … end` (a pipe into a `case`, which also traps the escaping
    # bindings). The metamutant must compile and both mutants must switch.
    @source """
    defmodule Mutare.WholeCallPipedFixture do
      import Mutare.Test.QueryDSL

      def go(v) do
        [x, y] |> unpack(v)
        x - y
      end
    end
    """

    @compile {:no_warn_undefined, Mutare.WholeCallPipedFixture}

    setup do
      {meta, sites, _next} =
        Mutare.transform_string(@source,
          file: "whole_piped.ex",
          mutators: [Mutare.Mutators.PatternSwap, Mutare.Test.UnpackMutator]
        )

      {[{mod, _}], _io} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)

      %{mod: mod, sites: sites}
    end

    test "both mutants get a site (the metamutant compiled)", %{sites: sites} do
      assert Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 5))
      assert Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))
    end

    test "each mutant switches independently and the bindings escape", %{mod: mod, sites: sites} do
      swap = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 5))
      call = Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))

      Selector.put(Selector.baseline())
      assert mod.go([5, 2]) == 3

      # `[y, x] |> unpack(v)` → y = 5, x = 2.
      Selector.put(swap.id)
      assert mod.go([5, 2]) == 2 - 5

      # `[x, y] |> unpack([9, 9])` → x = y = 9.
      Selector.put(call.id)
      assert mod.go([5, 2]) == 0
    end
  end

  describe "piped call whose binding pattern is a visible arg (not the LHS)" do
    # `value |> unpack2([x, y])` with routing `[:expression, :binding_pattern]` — the piped
    # value is an expression and the binding pattern is the stage's *visible* argument. The
    # equivalent direct call `unpack2(value, [x, y])` was always supported; the piped form was
    # missed because the clause only inspected the piped value's treatment.
    @source """
    defmodule Mutare.VisibleArgPipedFixture do
      import Mutare.Test.QueryDSL

      def go(v) do
        v |> unpack2([x, y])
        x - y
      end
    end
    """

    @compile {:no_warn_undefined, Mutare.VisibleArgPipedFixture}

    setup do
      {meta, sites, _next} =
        Mutare.transform_string(@source,
          file: "visible.ex",
          macros: [{Mutare.Test.QueryDSL, :unpack2, 2, [:expression, :binding_pattern]}]
        )

      {[{mod, _}], _io} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)

      %{mod: mod, sites: sites}
    end

    test "earns the structural swap mutant on the visible pattern arg", %{sites: sites} do
      site = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 5))
      assert site
      assert site.kind == :in_place
      assert site.mutated_code == "[y, x]"
    end

    test "the swap binds the other value and escapes", %{mod: mod, sites: sites} do
      site = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 5))

      Selector.put(Selector.baseline())
      assert mod.go([5, 2]) == 3

      # `v |> unpack2([y, x])` → `[y, x] = v` → y = 5, x = 2.
      Selector.put(site.id)
      assert mod.go([5, 2]) == 2 - 5
    end
  end

  describe "a whole-call mutation with NO structural pattern mutant (direct form)" do
    # Only the whole-call mutator is enabled — `PatternSwap`/`PatternWildcard` are off — so the
    # binding macro earns its whole-call mutant but *no* swap/wildcard pattern mutant. The
    # whole-call `Candidate.InPlace` must still be re-homed into the tuple-export selector
    # (computing the export from the pattern's bound vars alone); otherwise it survives as an
    # ordinary in-place selector that traps the escaping `x`/`y` inside its branches, leaving
    # `x - y` undefined and **failing the metamutant compile**.
    @source """
    defmodule Mutare.WholeCallOnlyDirectFixture do
      import Mutare.Test.QueryDSL

      def go(v) do
        unpack([x, y], v)
        x - y
      end
    end
    """

    @compile {:no_warn_undefined, Mutare.WholeCallOnlyDirectFixture}

    setup do
      {meta, sites, _next} =
        Mutare.transform_string(@source,
          file: "whole_only.ex",
          mutators: [Mutare.Test.UnpackMutator]
        )

      {[{mod, _}], _io} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)

      %{mod: mod, sites: sites}
    end

    test "the whole-call mutant gets a site and no pattern mutant is produced", %{sites: sites} do
      assert Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))
      refute Enum.any?(sites, &(&1.mutator in [:pattern_swap, :pattern_wildcard]))
    end

    test "the metamutant compiled and the whole-call mutant switches", %{mod: mod, sites: sites} do
      call = Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))

      Selector.put(Selector.baseline())
      assert mod.go([5, 2]) == 3

      # `unpack([x, y], [9, 9])` → x = y = 9; the bindings still escape to `x - y`.
      Selector.put(call.id)
      assert mod.go([5, 2]) == 0
    end
  end

  describe "a whole-call mutation with NO structural pattern mutant (piped form)" do
    # The piped twin: the stage `unpack(v)` carries the whole-call mutation on the `|>` RHS
    # child. With no pattern mutant to trigger re-homing, it would otherwise emit as its own
    # selector and this site's baseline would become the illegal `[x, y] |> case … end` — a
    # pipe into a `case` that also traps the escaping bindings. The export must be re-homed
    # from the pattern alone so the metamutant compiles.
    @source """
    defmodule Mutare.WholeCallOnlyPipedFixture do
      import Mutare.Test.QueryDSL

      def go(v) do
        [x, y] |> unpack(v)
        x - y
      end
    end
    """

    @compile {:no_warn_undefined, Mutare.WholeCallOnlyPipedFixture}

    setup do
      {meta, sites, _next} =
        Mutare.transform_string(@source,
          file: "whole_only_piped.ex",
          mutators: [Mutare.Test.UnpackMutator]
        )

      {[{mod, _}], _io} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)

      %{mod: mod, sites: sites}
    end

    test "the whole-call mutant gets a site and no pattern mutant is produced", %{sites: sites} do
      assert Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))
      refute Enum.any?(sites, &(&1.mutator in [:pattern_swap, :pattern_wildcard]))
    end

    test "the piped whole-call mutant's note rides through the re-home", %{sites: sites} do
      # The piped re-home (`|>` RHS → `Candidate.MacroPattern`) must also carry the note.
      call = Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))
      assert call.note == "whole-call mutant — bindings still escape"
    end

    test "the metamutant compiled and the whole-call mutant switches", %{mod: mod, sites: sites} do
      call = Enum.find(sites, &(&1.mutator == :unpack_call and &1.line == 5))

      Selector.put(Selector.baseline())
      assert mod.go([5, 2]) == 3

      # `[x, y] |> unpack([9, 9])` → x = y = 9; the bindings still escape to `x - y`.
      Selector.put(call.id)
      assert mod.go([5, 2]) == 0
    end
  end
end
