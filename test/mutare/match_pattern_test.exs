defmodule Mutare.MatchPatternTest do
  @moduledoc """
  The structural pattern families (variable swap, duplicate→wildcard) also mutate the LHS
  of a runtime `=` match **in statement position** (a non-final statement of a body block,
  where the match's value is discarded). A selector `case` can't wrap a match — its
  bindings would stop escaping — so the bound variables are re-exported through a tuple and
  rebound outside (`{vars} = case rhs do <pat> -> {vars} end`), the pattern hosted in a
  selector. Proven with one compile and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.{Report, Selector}

  @source """
  defmodule Mutare.MatchPatternFixture do
    def classify(point) do
      {x, y} = point
      x - y
    end

    def eq(t) do
      {a, a} = t
      a * 10
    end

    def mapped(m) do
      %{lat: la, lng: ln} = m
      la - ln
    end

    def listed(l) do
      [a, b] = l
      a - b
    end

    def inner(x) do
      {a, b} = {x + 1, x - 1}
      a - b
    end

    def bare(x) do
      y = x
      y + 1
    end

    def return_match(t) do
      :noop
      {a, b} = t
    end

    def for_pairs(list) do
      for p <- list, {hi, lo} = p do
        hi - lo
      end
    end

    def with_pairs(input) do
      with {:ok, payload} <- input,
           {key, val} = payload do
        val - key
      end
    end

    def underscored(t) do
      {_keep, y, z} = t
      _keep + y - z
    end

    def chained(point) do
      {x, y} = whole = point
      {whole, x - y}
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.MatchPatternFixture}

  setup_all do
    {metamutant, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(@source, file: "mp.ex")

    # `return_match/1`'s trailing `{a, b} = t` binds a/b unused (it returns the match
    # value); `underscored/1`'s re-exported `_keep` is read in the rewrite's inner-case
    # returns ("underscored variable used after being set"); plus any "cannot match"
    # broadening warning. All benign and captured so they do not clutter test output.
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

  alias Mutare.MatchPatternFixture, as: F

  defp id(sites, mutator, mutated_code, line) do
    site =
      Enum.find(
        sites,
        &(&1.mutator == mutator and &1.mutated_code == mutated_code and &1.line == line)
      )

    assert site, "no #{mutator} site #{inspect(mutated_code)} on line #{line}"
    site.id
  end

  # Transform + compile a one-off module carrying `directive` (an `import`/`alias` line)
  # ahead of a destructuring `=`, returning the compiled module. Warnings are captured.
  defp compile_with_directive(name, directive) do
    src = """
    defmodule #{name} do
      #{directive}

      def f(t) do
        {x, y} = t
        x - y
      end
    end
    """

    {meta, _sites, _next} = Mutare.Transform.transform_string_with_sites(src, file: "lex.ex")

    {[{module, _binary}], _io} =
      ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)

    module
  end

  test "match-pattern mutants are delivered in place (not lifted)", %{sites: sites, meta: meta} do
    refute meta =~ "__mutare_classify"
    refute meta =~ "__mutare_eq"
    refute meta =~ "__mutare_mapped"

    structural = Enum.filter(sites, &(&1.mutator in [:pattern_swap, :pattern_wildcard]))
    assert structural != []
    assert Enum.all?(structural, &(&1.kind == :in_place))
  end

  test "baseline behaves like the original" do
    assert F.classify({5, 2}) == 3
    assert F.eq({4, 4}) == 40
    assert F.mapped(%{lat: 9, lng: 4}) == 5
    assert F.listed([7, 2]) == 5
    assert F.inner(10) == 2
    assert F.bare(41) == 42
  end

  describe "tuple swap" do
    test "swapping a destructuring match binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{y, x}", 3))
      assert F.classify({5, 2}) == 2 - 5
    end

    test "still binds and escapes to the rest of the scope", %{sites: sites} do
      # The export tuple rebinds x/y in the enclosing scope, so the trailing `x - y`
      # sees the swapped values rather than an unbound variable.
      Selector.put(id(sites, :pattern_swap, "{y, x}", 3))
      assert is_integer(F.classify({1, 9}))
    end
  end

  describe "list swap" do
    test "swapping a list match binds the other value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "[b, a]", 18))
      assert F.listed([7, 2]) == 2 - 7
    end
  end

  describe "map value swap" do
    test "swapping map values binds the other key's value", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "%{lat: ln, lng: la}", 13))
      assert F.mapped(%{lat: 9, lng: 4}) == 4 - 9
    end
  end

  describe "for / with qualifiers (value-discarded matches)" do
    test "baseline for/with behave like the original" do
      assert F.for_pairs([{5, 2}, {9, 3}]) == [3, 6]
      assert F.with_pairs({:ok, {7, 2}}) == -5
      # a non-matching `<-` still routes (returns the unmatched value, no else)
      assert F.with_pairs(:error) == :error
    end

    test "a `for` `=` qualifier's pattern is mutated", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{lo, hi}", 38))
      assert F.for_pairs([{5, 2}, {9, 3}]) == [-3, -6]
    end

    test "a `with` `=` clause's pattern is mutated", %{sites: sites} do
      Selector.put(id(sites, :pattern_swap, "{val, key}", 45))
      assert F.with_pairs({:ok, {7, 2}}) == 5
    end
  end

  describe "underscore-prefixed bindings" do
    # Regression: `_keep` is a real binding read later (`_keep + y - z`). The export set
    # must include it — omitting it (as reusing `var_name/1` did) left `_keep` undefined
    # in the rest of the block, so the metamutant *failed to compile* (setup_all would
    # crash). Only bare `_` is dropped. The baseline value proves it both compiles and
    # rebinds `_keep` correctly.
    test "an `_name` binding is re-exported so later reads still resolve", %{sites: sites} do
      assert F.underscored({10, 5, 2}) == 10 + 5 - 2

      Selector.put(id(sites, :pattern_swap, "{_keep, z, y}", 51))
      assert F.underscored({10, 5, 2}) == 10 + 2 - 5
    end
  end

  describe "a chained match re-exports the chain's own bindings" do
    # Regression: `{x, y} = whole = point` is a *chained* match. The tuple-re-export delivery
    # makes the RHS (`whole = point`) the selector's inner-case scrutinee, so `whole` — bound by
    # the chain link — was trapped inside the branch and left undefined for the trailing
    # `{whole, …}` read, so the metamutant failed to compile (setup_all would crash). This is the
    # exact shape mutare_ecto hit with `%QueryCall{…} = call = QueryCall.parse(node)`. The fix
    # appends every chain var to the export tuple so it rides back out through the outer rebind.
    test "the chain variable escapes to the rest of the scope (baseline)" do
      assert F.chained({5, 2}) == {{5, 2}, 3}
    end

    test "the pattern still swaps while the chain variable stays bound", %{sites: sites} do
      # `whole` (the chain var) is rebound in the enclosing scope, and the swapped `{y, x}`
      # makes the trailing `x - y` read the transposed values — both reachable at once.
      Selector.put(id(sites, :pattern_swap, "{y, x}", 56))
      assert F.chained({5, 2}) == {{5, 2}, 2 - 5}
    end
  end

  describe "MatchError is raised independently of the target's lexical env" do
    # A real `=` always raises Elixir.MatchError on a non-match. The rewrite's fallback
    # clause must too — so it emits the *absolute, fully-qualified*
    # `Elixir.Kernel.raise(Elixir.MatchError, …)`, not the lexically-resolved
    # `raise MatchError`, which a module excluding `Kernel.raise/2`, aliasing `MatchError`,
    # *or rebinding the `Kernel` name itself* would break or redirect.
    test "the generated fallback is fully qualified" do
      {meta, _sites, _next} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule Z do\n  def f(t) do\n    {x, y} = t\n    x - y\n  end\nend\n"
        )

      assert meta =~ "Elixir.Kernel.raise(Elixir.MatchError, term:"
      refute meta =~ "-> raise MatchError"
    end

    test "compiles and raises MatchError when Kernel.raise/2 is excluded" do
      mod =
        compile_with_directive(
          "Mutare.MatchPatternExclFixture",
          "import Kernel, except: [raise: 2]"
        )

      assert_raise MatchError, fn -> mod.f(:not_a_tuple) end
    end

    test "raises Elixir.MatchError even when MatchError is aliased away" do
      mod =
        compile_with_directive(
          "Mutare.MatchPatternAliasFixture",
          "alias ArgumentError, as: MatchError"
        )

      assert_raise MatchError, fn -> mod.f(:not_a_tuple) end
    end

    test "raises Elixir.MatchError even when the Kernel name itself is rebound" do
      # `alias String, as: Kernel` would make a plain `Kernel.raise` resolve to the
      # nonexistent `String.raise` (a compile error); the *absolute* `Elixir.Kernel.raise`
      # is led by `:Elixir`, which alias resolution never rewrites, so it still works.
      mod =
        compile_with_directive(
          "Mutare.MatchPatternKernelAliasFixture",
          "alias String, as: Kernel"
        )

      assert_raise MatchError, fn -> mod.f(:not_a_tuple) end
    end
  end

  describe "self-constraint variables don't gain a spurious unused warning" do
    # A variable used only to *constrain* the pattern — a repeated binding `{a, a}`, or a
    # bitstring size var `<<n, r::size(n)>>` — has its "unused" warning suppressed in the
    # original by that self-use. The export tuple repeats each bound var by its occurrence
    # count, so the rebind keeps the self-use (`{a, a} = …`, not `{a} = …`) and the
    # metamutant doesn't gain a warning the original never had.
    test "a repeated binding constrains without a warning when the var is unused later" do
      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule R do\n  def f(t) do\n    {a, a} = t\n    :ok\n  end\nend\n"
        )

      # the rewrite must actually fire, else the assertion below is vacuous
      assert Enum.any?(sites, &(&1.mutator == :pattern_wildcard))
      assert meta =~ "{a, a} ="

      {_compiled, io} = ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)
      refute io =~ "is unused"
    end

    test "a bitstring size variable does not warn when unused later" do
      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule S do\n  def f(t) do\n    <<a, b, rest::binary-size(a)>> = t\n    {b, rest}\n  end\nend\n"
        )

      assert Enum.any?(sites, &(&1.mutator == :pattern_swap))

      {_compiled, io} = ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)
      refute io =~ ~s(variable "a" is unused)
    end
  end

  describe "duplicate → wildcard" do
    test "thinning one occurrence drops the equality match (two mutants)", %{sites: sites} do
      first = id(sites, :pattern_wildcard, "{_, a}", 8)
      second = id(sites, :pattern_wildcard, "{a, _}", 8)
      refute first == second

      # `{_, a}` binds the second element; `{a, _}` the first. Either way the equality
      # assertion `{a, a}` enforced is gone, so an unequal tuple no longer raises.
      Selector.put(first)
      assert F.eq({4, 9}) == 90

      Selector.put(second)
      assert F.eq({4, 9}) == 40
    end

    test "never wildcards both occurrences (thin mode, binding preserved)", %{sites: sites} do
      refute Enum.any?(sites, &(&1.mutator == :pattern_wildcard and &1.mutated_code == "{_, _}"))
    end
  end

  describe "scope and position" do
    test "a final-statement match is not rewritten (its value is consumed)", %{sites: sites} do
      refute Enum.any?(
               sites,
               &(&1.line == 34 and &1.mutator in [:pattern_swap, :pattern_wildcard])
             )

      assert F.return_match({1, 2}) == {1, 2}
    end

    test "a bare `var = expr` match is never offered", %{sites: sites} do
      refute Enum.any?(
               sites,
               &(&1.line == 28 and &1.mutator in [:pattern_swap, :pattern_wildcard])
             )
    end

    test "a mutation in the matched expression still fires (baseline path)", %{sites: sites} do
      # `{a, b} = {x + 1, x - 1}` — the arithmetic in the rhs is mutated independently;
      # it lives on the selector catch-all's *emitted* rhs, so it fires when its id is
      # active (a non-match id, so the match selector takes its baseline branch).
      Selector.put(id(sites, :arithmetic, "x - 1", 23))
      # baseline `inner(10)` = (10+1) - (10-1) = 2; with `x + 1` → `x - 1` the rhs is
      # `{9, 9}`, so `a - b` = 0 — proving the rhs mutation is reachable post-rewrite.
      assert F.inner(10) == 0
    end
  end

  test "an unknown id falls through to every original match" do
    Selector.put(987_654)
    assert F.classify({5, 2}) == 3
    assert F.eq({4, 4}) == 40
    assert F.mapped(%{lat: 9, lng: 4}) == 5
    assert F.listed([7, 2]) == 5
  end

  test "renders a match-pattern swap as a focused one-line diff", %{sites: sites} do
    site = Enum.find(sites, &(&1.mutator == :pattern_swap and &1.line == 3))

    assert Report.header(site) == "mp.ex:3  [pattern_swap, in-place]  SURVIVED"

    assert Report.diff(site, @source) ==
             "-    {x, y} = point\n+    {y, x} = point"
  end

  describe "a bare `=` node is never offered to mutators (invariant)" do
    # The dedicated `analyze({:=, …})` clause rebuilds the match WITHOUT `offer` (LHS → :pattern,
    # RHS → context), so no mutator — built-in or custom — can produce a *whole-`=`* mutation.
    # This is *why* the `MatchPattern` path is safe from the shadowing / binding-trap hazards the
    # *macro* path has (there the node IS offered, so whole-call mutants must be re-homed into the
    # tuple-export selector — see `Transform.Analyze.rehome_call_mutations/2` and NOTES "Whole-call
    # mutants on a binding macro"). If this test fails, a `=` node has become offerable and a
    # whole-`=` mutation of a value-discarded binding match now needs that same re-home.
    @probe_source """
    defmodule Mutare.AssignProbeFixture do
      def go(pair) do
        [x, y] = pair
        probe()
        x - y
      end
    end
    """

    test "a probe mutator matching `=` earns a site on an offered node but none on the `=`" do
      # Sanity: the probe *does* target a `=` node — so an absent `=` site means the node was
      # never offered, not that the mutator simply failed to match.
      assert Mutare.Test.AssignMutator.mutate({:=, [], [{:x, [], nil}, {:y, [], nil}]}) != :skip

      {_meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(@probe_source,
          file: "probe.ex",
          mutators: [Mutare.Test.AssignMutator]
        )

      # Liveness: the probe IS running in the pipeline — it mutated the offered `probe()` call.
      assert Enum.find(sites, &(&1.mutator == :assign_probe and &1.line == 4))

      # Invariant: the `=` on line 3 earned no mutant — the node was never offered.
      refute Enum.any?(sites, &(&1.mutator == :assign_probe and &1.line == 3))
    end
  end

  describe "Mutare.Transform.Analyze.MatchPatterns mechanics" do
    test "a chain that rebinds an outer pinned name is not rewritten" do
      # The source match snapshots `x` for `^x` before evaluating the right-associative chain.
      # Moving the chain into an inner-case scrutinee would rebind `x` first, making the pin see
      # the new value and changing the baseline from MatchError to success. This shape therefore
      # gets no structural candidate; the original match stays intact.
      source = """
      defmodule Mutare.MPPinnedChainFixture do
        def f(point) do
          x = 1
          {^x, y, q} = {x, z, q} = point
          {x, y, z, q}
        end
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PatternSwap]
        )

      assert sites == []

      {compiled, _io} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)

      [{module, _binary}] = compiled

      assert module.f({1, 3, 4}) == {1, 3, 3, 4}
      assert_raise MatchError, fn -> module.f({2, 3, 4}) end
    end

    test "a chained match's RHS-bound vars are appended to the export tuple" do
      # `{a, b} = call = build(node)` — the chain link `call = …` binds `call`, which the
      # tuple-re-export delivery would trap inside the inner-case scrutinee. `export_with_rhs_chain/2`
      # appends it to the export so the outer rebind becomes `{a, b, call} = case … end`, keeping
      # `call` in scope for the trailing `combine(call, …)`. Without it the metamutant raised
      # "undefined variable call" (mutare_ecto's poison).
      source = """
      defmodule Mutare.MPChainFixture do
        def go(node) do
          {a, b} = call = build(node)
          combine(call, a - b)
        end

        defp build(n), do: {n, n}
        defp combine(c, d), do: {c, d}
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PatternSwap]
        )

      assert Enum.any?(sites, &(&1.mutator == :pattern_swap and &1.mutated_code == "{b, a}"))
      assert meta =~ "{a, b, call} ="

      {compiled, io} = ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)
      assert [{_module, _binary}] = compiled
      refute io =~ "undefined variable"
    end

    test "a chained match's self-constraining link keeps its occurrence multiplicity" do
      # `{x, y} = {a, a} = point` — `a` is bound by a *self-constraint* (`{a, a}`) in the chain.
      # The appended export var must repeat `a` by its occurrence count (`{x, y, a, a} = …`), not
      # collapse to a single `a`: the repeated slot keeps the self-use, so an `a` the rest of the
      # scope never reads doesn't gain an "unused variable" warning the original `{a, a} = point`
      # never had. (The two slots are the same binding, so the rebind re-imposes no real constraint.)
      source = """
      defmodule Mutare.MPSelfConstraintFixture do
        def f(point) do
          {x, y} = {a, a} = point
          x - y
        end
      end
      """

      {meta, _sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PatternSwap]
        )

      assert meta =~ "{x, y, a, a} ="

      {_compiled, io} = ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)
      refute io =~ "is unused"
    end

    test "a module-attribute literal in a chain pattern is not exported as a binding" do
      # `@tag` expands to a literal in the chain pattern; the inner `tag` AST node only looks
      # variable-shaped. Exporting it would make every selector branch reference an undefined
      # `tag` variable and prevent the metamutant from compiling.
      source = """
      defmodule Mutare.MPAttributeChainFixture do
        @tag :point

        def f(point) do
          {x, y} = {@tag, _} = point
          {x, y}
        end
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PatternSwap]
        )

      assert Enum.any?(sites, &(&1.mutator == :pattern_swap and &1.mutated_code == "{y, x}"))
      refute meta =~ "{x, y, tag} ="

      {compiled, io} = ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(meta) end)
      assert [{module, _binary}] = compiled
      refute io =~ "undefined variable"
      assert module.f({:point, 7}) == {:point, 7}
    end

    test "a non-chained match's export is unchanged (no spurious passthrough vars)" do
      # A plain `<pat> = e` (non-`=` RHS) must export only the pattern's own vars — the RHS
      # `point` is a *read*, not a binding, so `rhs_chain_bound_names/1` returns `[]` and the
      # export stays `{x, y}` (the 2-tuple form), never `{x, y, point}`.
      source = """
      defmodule Mutare.MPPlainFixture do
        def f(point) do
          {x, y} = point
          x - y
        end
      end
      """

      {meta, _sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PatternSwap]
        )

      assert meta =~ "{x, y} ="
      refute meta =~ "point} ="
    end

    test "a non-final statement that is not a binding macro is analyzed normally" do
      # `binding_pattern_macro/1`'s fallback returns nil for any statement that isn't a
      # binding-escaping macro call. A bare-variable statement (`{:x, meta, nil}`, whose
      # args slot is not a list) reaches that fallback; dropping it raises FunctionClauseError.
      source = """
      defmodule Mutare.MPFallbackFixture do
        def f(x) do
          x
          :ok
        end
      end
      """

      {meta, _sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PatternSwap]
        )

      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a leading comment on a destructuring `=` is stripped from the recorded diff" do
      # Sourceror parks the statement's leading comment on the pattern's leftmost leaf;
      # `strip_comments/1` must remove it (deleting `:leading_comments` on every pattern node)
      # so the recorded original/mutated render the bare pattern, not the comment text.
      source = """
      defmodule Mutare.MPCommentFixture do
        def f(t) do
          # the destructure
          {x, y} = t
          x - y
        end
      end
      """

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PatternSwap]
        )

      swap = Enum.find(sites, &(&1.mutator == :pattern_swap))
      assert swap.original_code == "{x, y}"
      assert swap.mutated_code == "{y, x}"
    end

    test "a known macro's binding-pattern arg is found by its routing position, not the first arg" do
      # `binding_pattern_index/1` finds the arg whose routing is `:binding_pattern`. When a
      # registered macro carries it at a *non-first* position, the structural mutant must target
      # that arg — not arg 0. (Forcing the search predicate `true` would always pick arg 0.)
      source = """
      defmodule Mutare.MPRoutingFixture do
        def f(v) do
          Foo.unpack(v, [x, y])
          x - y
        end
      end
      """

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.PatternSwap],
          macro_routes: [{Foo, :unpack, [:expression, :binding_pattern]}]
        )

      assert Enum.filter(sites, &(&1.mutator == :pattern_swap))
             |> Enum.map(&{&1.original_code, &1.mutated_code}) == [{"[x, y]", "[y, x]"}]
    end
  end
end
