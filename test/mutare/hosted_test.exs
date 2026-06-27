defmodule Mutare.HostedTest do
  @moduledoc """
  The **selector-host** extensions: mutating *inside* a compile-time DSL fragment (the
  deep `Ecto.from`/`where` case) where core can't splice a bare selector and can't vouch
  for the fragment's foreign semantics. Two pieces work together:

    * the `:routing` **shape-aware classifier** (`c:Mutare.Mutator.MacroAware.macro_routing/1`) decides,
      per call, whether the `filter` condition is a `:hosted` DSL fragment (a comparison) or
      ordinary `:expression` data (a keyword list);
    * the **selector host** (`c:Mutare.Mutator.MacroAware.host/2`) hands core the logical original/mutant
      fragments and a `splice`, and core builds the id-gated selector `case`, records the Site
      (showing only the `x > 1` → `x >= 1` fragment diff), emits coverage, and weaves it in.

  Proven with one compile and runtime switching (`Mutare.Test.HostDSL`/`HostMutator`).
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false

  alias Mutare.Selector

  @source """
  defmodule Mutare.HostedFixture do
    import Mutare.Test.HostDSL

    def direct(x) do
      filter([:ok], x > 1)
    end

    def piped(x) do
      [:ok] |> filter(x > 1)
    end

    def data(label) do
      filter([label], tag: "keep")
    end
  end
  """

  @compile {:no_warn_undefined, Mutare.HostedFixture}
  @compile {:no_warn_undefined, Mutare.BindHostedFixture}

  @mutators [:string, :relational, Mutare.Test.HostMutator]

  setup_all do
    {metamutant, sites, _next_id} =
      Mutare.transform_string(@source, file: "hosted.ex", mutators: @mutators)

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

  alias Mutare.HostedFixture, as: F
  alias Mutare.BindHostedFixture, as: F2

  defp id(sites, mutator, mutated_code, line) do
    site =
      Enum.find(
        sites,
        &(&1.mutator == mutator and &1.mutated_code == mutated_code and &1.line == line)
      )

    assert site, "no #{mutator} site #{inspect(mutated_code)} on line #{line}"
    site.id
  end

  describe "the hosted fragment is mutated by the host (not core)" do
    test "the host's comparison-flip catalog produces the mutant Sites", %{sites: sites} do
      hosted = Enum.filter(sites, &(&1.mutator == :host_filter))
      assert hosted != []

      # Each flip is recorded as a focused, scaffolding-free `:in_place` Site.
      assert Enum.all?(hosted, &(&1.kind == :in_place))
      assert Enum.all?(hosted, &(&1.original_code == "x > 1"))

      # `direct/1`'s `x > 1` flips to both `x >= 1` (boundary) and `x < 1` (reversal).
      assert id(sites, :host_filter, "x >= 1", 5)
      assert id(sites, :host_filter, "x < 1", 5)
    end

    test "core does NOT mutate the hosted comparison in place", %{sites: sites} do
      # `:relational` is enabled, but the `x > 1` fragment is routed `:hosted` (raw to core),
      # so Relational never sees it — only the host's own catalog fires there.
      refute Enum.any?(sites, &(&1.mutator == :relational and &1.line == 5))
      refute Enum.any?(sites, &(&1.mutator == :relational and &1.line == 9))
    end

    test "the woven selector and coverage record live inside the DSL call", %{meta: meta} do
      # The selector `case` is spliced into `filter`'s condition position…
      assert meta =~ "filter(\n      [:ok],\n      case mutare_active do"
      # …and the catch-all records the hosted ids (inert outside the probe).
      assert meta =~ ":mutare_cov.hit("
    end
  end

  describe "shape-aware routing (the :routing classifier)" do
    test "a comparison condition is hosted; keyword data is an ordinary expression", %{
      sites: sites
    } do
      # The hosted comparison earns `:host_filter` sites (above). The *data* condition
      # `tag: "keep"` is routed `:expression`, so a core literal family mutates it in place.
      assert id(sites, :string, "\"\"", 13)
      assert id(sites, :string, "\"mutare\"", 13)

      # …and the data condition is never treated as a hosted fragment.
      refute Enum.any?(sites, &(&1.mutator == :host_filter and &1.line == 13))
    end
  end

  describe "a host target's per-mutant note rides onto the Site and the report" do
    defp site(sites, mutated_code, line) do
      Enum.find(
        sites,
        &(&1.mutator == :host_filter and &1.mutated_code == mutated_code and &1.line == line)
      )
    end

    test "a noted mutant carries the note; a bare mutant does not", %{sites: sites} do
      # `x > 1`'s boundary flip (`x >= 1`) is the `%Mutare.Mutator.Mutation{}` form → Site.note set;
      # its reversal (`x < 1`) is a bare node → Site.note nil.
      assert site(sites, "x >= 1", 5).note == "kill may require boundary data"
      assert site(sites, "x < 1", 5).note == nil
    end

    test "the survivor header appends the note", %{sites: sites} do
      noted = site(sites, "x >= 1", 5)
      header = Mutare.Report.header(noted)

      assert header =~ "SURVIVED  — kill may require boundary data"
      # A bare mutant's header has no trailing note.
      assert Mutare.Report.header(site(sites, "x < 1", 5)) =~ ~r/SURVIVED$/
    end
  end

  describe "baseline behaves like the original" do
    test "every clause runs its DSL untouched at the baseline mutant" do
      assert F.direct(2) == [:ok]
      assert F.direct(1) == []
      assert F.piped(2) == [:ok]
      assert F.piped(1) == []
      assert F.data(:row) == [:row]
    end
  end

  describe "switching to a hosted mutant changes the DSL behaviour" do
    test "the boundary flip `x > 1` → `x >= 1` (directly written)", %{sites: sites} do
      Selector.put(id(sites, :host_filter, "x >= 1", 5))
      # 1 >= 1 is now true, so the row survives the filter.
      assert F.direct(1) == [:ok]
      # an unrelated input is unaffected
      assert F.direct(2) == [:ok]
    end

    test "the reversal flip `x > 1` → `x < 1` (directly written)", %{sites: sites} do
      Selector.put(id(sites, :host_filter, "x < 1", 5))
      assert F.direct(2) == []
      assert F.direct(0) == [:ok]
    end

    test "a piped DSL stage hosts the same way (`q |> filter(cond)`)", %{sites: sites} do
      Selector.put(id(sites, :host_filter, "x >= 1", 9))
      assert F.piped(1) == [:ok]
    end

    test "only the active mutant's branch fires; others stay baseline", %{sites: sites} do
      # Activating `direct/1`'s mutant leaves `piped/1` at baseline.
      Selector.put(id(sites, :host_filter, "x >= 1", 5))
      assert F.piped(1) == []
    end
  end

  describe "poison recovery (a hosted mutant dropped via :skip_ids)" do
    test "the skipped mutant is poisoned, ids stay stable, and the build still compiles", %{
      sites: sites
    } do
      target = id(sites, :host_filter, "x >= 1", 5)

      {meta2, sites2, _next} =
        Mutare.transform_string(@source,
          file: "hosted.ex",
          mutators: @mutators,
          skip_ids: MapSet.new([target])
        )

      # The dropped mutant's site is still recorded (`poisoned`, for the denominator and id
      # stability) — its woven clause is gone, so the build compiles.
      assert Enum.find(sites2, &(&1.id == target)).poisoned

      # Every other id is unchanged across the rebuild (the counter advances even for the
      # skipped id) — the contract poison recovery leans on.
      stable = fn list -> Map.new(list, &{&1.id, {&1.mutator, &1.mutated_code, &1.line}}) end
      assert Map.delete(stable.(sites2), target) == Map.delete(stable.(sites), target)

      # The skipped selector now hosts only its surviving sibling; the metamutant compiles.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        source = String.replace(meta2, "Mutare.HostedFixture", "Mutare.HostedFixturePoison")
        assert [{_module, _binary}] = Code.compile_string(source)
      end)
    end
  end

  describe "a host mutator configured more than once (the `:as` rename)" do
    test "each configured spec emits its own hosted mutants under its own name" do
      # The hosting mutator is a *module*, but two `:as` configs make two distinct families
      # (own name, own opts). The hosted path must run *every* matching spec — exactly as the
      # ordinary mutation path does — not just the first, or the second config silently vanishes.
      {_meta, sites, _next} =
        Mutare.transform_string(@source,
          file: "hosted.ex",
          mutators: [
            {Mutare.Test.HostMutator, as: :host_a},
            {Mutare.Test.HostMutator, as: :host_b}
          ]
        )

      for name <- [:host_a, :host_b] do
        flips = Enum.filter(sites, &(&1.mutator == name))

        assert Enum.any?(flips, &(&1.mutated_code == "x >= 1" and &1.line == 5)),
               "expected a hosted #{name} mutant `x >= 1` on line 5"

        assert Enum.any?(flips, &(&1.mutated_code == "x < 1" and &1.line == 5)),
               "expected a hosted #{name} mutant `x < 1` on line 5"
      end

      # Both families' mutants coexist with distinct ids (the second config is not dropped).
      a_ids = for s <- sites, s.mutator == :host_a, do: s.id
      b_ids = for s <- sites, s.mutator == :host_b, do: s.id
      assert length(a_ids) == length(b_ids) and a_ids != []
      assert MapSet.disjoint?(MapSet.new(a_ids), MapSet.new(b_ids))
    end
  end

  describe "a static :hosted at the piped-value position is rejected (not silently dropped)" do
    test "raises with an actionable message pointing at :routing" do
      source = """
      defmodule Mutare.PipedHostFixture do
        import Mutare.Test.PipedDSL

        def f(x) do
          (x > 1) |> rotate()
        end
      end
      """

      assert_raise ArgumentError, ~r/argument 0 as :hosted.*piped.*:routing/s, fn ->
        Mutare.transform_string(source,
          file: "p.ex",
          mutators: [Mutare.Test.PipedHostMutator]
        )
      end
    end

    test "the same static :hosted at argument 0 hosts fine when written directly (not piped)" do
      source = """
      defmodule Mutare.DirectHostFixture do
        import Mutare.Test.PipedDSL

        def f(x) do
          rotate(x > 1)
        end
      end
      """

      # Direct call: argument 0 is a visible argument, so it is hosted normally (no raise).
      # `host/2` returns [] in this fixture, so there are simply no hosted sites — the point
      # is that resolution does not raise.
      {_meta, _sites, _next} =
        Mutare.transform_string(source, file: "d.ex", mutators: [Mutare.Test.PipedHostMutator])
    end
  end

  describe "a :routing classifier routing :hosted with no host/2 is rejected (not silently dropped)" do
    test "raises with an actionable message pointing at host/2" do
      # `Mutare.Test.NoDeliveryHostMutator` passes build (a `:routing` spec only needs
      # `macro_routing/1`), but its classifier routes the comparison condition `:hosted` while
      # the mutator omits `host/2` — undeliverable. Resolve raises rather than leaving the
      # fragment raw and dropping the mutation without a trace.
      source = """
      defmodule Mutare.NoDeliveryFixture do
        import Mutare.Test.HostDSL

        def f(x) do
          filter([:ok], x > 1)
        end
      end
      """

      assert_raise ArgumentError, ~r/routed an argument as :hosted.*host\/2/s, fn ->
        Mutare.transform_string(source,
          file: "nd.ex",
          mutators: [Mutare.Test.NoDeliveryHostMutator]
        )
      end
    end
  end

  describe "a hosted macro that ALSO binds escaping variables (:binding_pattern + :hosted)" do
    # `pick([a, b], x > 1)` in a value-discarded position carries *both* a `Candidate.Hosted`
    # (the comparison fragment, arg 1) and a `Candidate.MacroPattern` (the escaping pattern,
    # arg 0). The hosted emit path must deliver the MacroPattern through the tuple-export
    # rewrite (`BindingEscapeEmit.macro_pattern_site/3`), not an ordinary node-wrapping selector — else the
    # mutant branch is a bare mutated-pattern AST with unbound vars and the metamutant won't
    # compile, and the bindings would never escape.
    @bind_source """
    defmodule Mutare.BindHostedFixture do
      import Mutare.Test.HostDSL

      def run(x) do
        pick([a, b], x > 1)
        a * 10 + b
      end
    end
    """

    @bind_mutators [:pattern_swap, :relational, Mutare.Test.HostMutator]

    test "the metamutant compiles and both the binding and the hosted fragment mutate" do
      {meta, sites, _next} =
        Mutare.transform_string(@bind_source, file: "bind.ex", mutators: @bind_mutators)

      # Both candidate kinds land on the same line-5 call.
      swap = id(sites, :pattern_swap, "[b, a]", 5)
      ge = id(sites, :host_filter, "x >= 1", 5)

      # The escaping bindings are re-exported through a tuple (`{a, b} = case … end`), and the
      # mutated pattern rides a real `pick(...)` call inside its branch — not the broken bare
      # `[b, a]` an ordinary node-wrapping selector (`emit_site/3`) would emit as the branch body.
      assert meta =~ "{a, b} =\n      case mutare_active do"
      assert meta =~ "pick([b, a], x > 1)"

      # The regression catch: without the dispatch fix the mutant branch references unbound
      # `a`/`b`, so the metamutant fails to compile.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert [{_m, _b}] = Code.compile_string(meta)
      end)

      # Baseline: `x > 1` selects [1, 2] for x = 2, [0, 0] for x ≤ 1; the bindings escape to
      # `a * 10 + b`, so order is observable.
      Selector.put(Selector.baseline())
      assert F2.run(2) == 12
      assert F2.run(1) == 0

      # The binding mutation (swap `[a, b]` → `[b, a]`) changes which value each var binds —
      # proving the bindings escaped through the tuple-export, not trapped in a branch.
      Selector.put(swap)
      assert F2.run(2) == 21

      # The hosted mutation (`x > 1` → `x >= 1`) fires on the same node, independently.
      Selector.put(ge)
      assert F2.run(1) == 12
    end
  end

  describe "per-keyword-pair routing ({:keyword, value_treatments}) + :pinned values" do
    @kw_source """
    defmodule Mutare.KwFixture do
      import Mutare.Test.HostDSL

      def assign(q) do
        set(q, name: "keep", count: 5)
      end
    end
    """

    setup do
      {meta, sites, _next} =
        Mutare.transform_string(@kw_source,
          file: "kw.ex",
          mutators: [:string, :literal, :atom, Mutare.Test.HostMutator]
        )

      %{meta: meta, sites: sites}
    end

    test "routes each pair's value by its own treatment, leaving the keys raw", %{sites: sites} do
      # `name: "keep"` — the string value is routed :pinned, so a core literal family mutates it
      # (its *own* name on the Site — the value mutation stays core's, not the host's).
      assert Enum.any?(sites, &(&1.mutator == :string and &1.mutated_code == "\"\""))
      assert Enum.any?(sites, &(&1.mutator == :string and &1.mutated_code == "\"mutare\""))

      # `count: 5` — the integer value is routed :skip, so it is left raw despite :literal
      # being enabled (it would otherwise offer 6/4/0).
      refute Enum.any?(sites, &(&1.mutator == :literal))

      # The keys `name`/`count` are field names, never mutated — even though :atom is enabled
      # and would otherwise rewrite a bare atom. This is the per-pair routing's defining
      # behaviour (a plain :expression on the whole list would mutate the keys too).
      refute Enum.any?(sites, &(&1.mutator == :atom))
    end

    test "a :pinned value's selector is ^-pinned (not a bare case)", %{meta: meta} do
      # The string value's selector is delivered `^case … end` — the pin a DSL value position
      # requires (Ecto rejects a bare `case` there). The recorded Site stays the clean
      # `"keep"` → `""` diff (no `^`), asserted above; the `^` is emit-only scaffolding.
      assert meta =~ ~r/name:\s*\^\(?case mutare_active do/
      # …and the integer value, routed :skip, carries no selector at all.
      assert meta =~ ~r/count: 5\b/
    end

    test "the (pinned) metamutant still compiles", %{meta: meta} do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:compiled, Code.compile_string(meta)})
      end)

      assert_received {:compiled, [{module, _binary}]}
      :code.purge(module)
      :code.delete(module)
    end
  end

  describe "nested per-keyword-pair routing ({:keyword, [{:keyword, …}]})" do
    # A value that is itself a keyword list — the `from(S, where: [x: v])` shape. The `filters:`
    # value routes `{:keyword, [:pinned]}` (its `name: "keep"` pair's value pinned), `count: 5`
    # stays `:skip`.
    @nested_source """
    defmodule Mutare.NestedKwFixture do
      import Mutare.Test.HostDSL

      def assign(q) do
        set(q, filters: [name: "keep"], count: 5)
      end
    end
    """

    setup do
      {meta, sites, _next} =
        Mutare.transform_string(@nested_source,
          file: "nested_kw.ex",
          mutators: [:string, :literal, :atom, Mutare.Test.HostMutator]
        )

      %{meta: meta, sites: sites}
    end

    test "recurses into a value that is itself a keyword list", %{sites: sites, meta: meta} do
      # The nested string value `name: "keep"` still mutates — its own :string family on the Site,
      # the value mutation staying core's — so a keyword list *whose values are keyword lists*
      # routes too (the recursive `{:keyword, …}` arm).
      assert Enum.any?(sites, &(&1.mutator == :string and &1.mutated_code == "\"\""))
      assert Enum.any?(sites, &(&1.mutator == :string and &1.mutated_code == "\"mutare\""))

      # Delivered `^`-pinned *inside* the nested list (`filters: [name: ^(case … end)]`).
      assert meta =~ ~r/name:\s*\^\(?case mutare_active do/

      # Every key — the nested `name`, the outer `filters`/`count` — is a field name, never
      # mutated, even though :atom is enabled (the recursion leaves keys raw at every depth).
      refute Enum.any?(sites, &(&1.mutator == :atom))

      # `count: 5` (the outer integer value) is still routed :skip — no :literal site.
      refute Enum.any?(sites, &(&1.mutator == :literal))
    end

    test "the nested-keyword metamutant compiles", %{meta: meta} do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:compiled, Code.compile_string(meta)})
      end)

      assert_received {:compiled, [{module, _binary}]}
      :code.purge(module)
      :code.delete(module)
    end
  end

  describe "a :hosted nested in a {:keyword, …} routing" do
    test "is delivered through the whole-node host" do
      source = """
      defmodule Mutare.KeywordHostedFixture do
        import Mutare.Test.HostDSL

        def assign(q) do
          set(q, name: "keep", count: 5)
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.transform_string(source,
          file: "kwh.ex",
          mutators: [Mutare.Test.KeywordHostedMutator]
        )

      assert Enum.any?(
               sites,
               &(&1.original_code == ~s|"keep"| and &1.mutated_code == ~s|"keep!"|)
             )

      assert meta =~ "case mutare_active do"

      # Two keyword leaves (`name`, `count`) host on one macro node — the multi-target weave; make
      # sure the woven metamutant actually compiles, not just that a `case` string is present.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:keyword_hosted_compiled, Code.compile_string(meta)})
      end)

      assert_received {:keyword_hosted_compiled, [{module, _binary}]}
      :code.purge(module)
      :code.delete(module)
    end

    test "is found recursively inside a nested keyword value" do
      source = """
      defmodule Mutare.NestedKeywordHostedFixture do
        import Mutare.Test.HostDSL

        def assign(q) do
          set(q, filters: [name: "keep"])
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.transform_string(source,
          file: "nkwh.ex",
          mutators: [Mutare.Test.KeywordHostedMutator]
        )

      assert Enum.any?(
               sites,
               &(&1.original_code == ~s|"keep"| and &1.mutated_code == ~s|"keep!"|)
             )

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:nested_keyword_hosted_compiled, Code.compile_string(meta)})
      end)

      assert_received {:nested_keyword_hosted_compiled, [{module, _binary}]}
      :code.purge(module)
      :code.delete(module)
    end
  end

  describe "classifier output is validated (an unrecognised treatment is rejected)" do
    test "an unknown treatment atom raises with the offending value" do
      # `Mutare.Test.UnknownTreatmentMutator` routes the `filter` condition `:bogus`. Without
      # validation it would fall through `route_macro_arg/3`'s `:expression` catch-all and silently
      # mutate the fragment in place; `Resolve.MacroStamp` rejects it loudly instead.
      source = """
      defmodule Mutare.UnknownTreatmentFixture do
        import Mutare.Test.HostDSL

        def f(x) do
          filter([:ok], x > 1)
        end
      end
      """

      assert_raise ArgumentError, ~r/unrecognised treatment :bogus/, fn ->
        Mutare.transform_string(source,
          file: "ut.ex",
          mutators: [Mutare.Test.UnknownTreatmentMutator]
        )
      end
    end

    test "a non-list macro_routing/1 return raises" do
      # Defensive: a classifier that returns a non-list (a contract violation) is caught with a
      # clear message rather than crashing inside the host-injection `Enum.map`.
      source = """
      defmodule Mutare.BadShapeFixture do
        import Mutare.Test.HostDSL

        def f(x) do
          filter([:ok], x > 1)
        end
      end
      """

      assert_raise ArgumentError, ~r/must return a list of treatments/, fn ->
        Mutare.transform_string(source, file: "bs.ex", mutators: [Mutare.Test.BadShapeMutator])
      end
    end
  end

  describe "a :pinned compound value is rejected (not silently poisoned)" do
    test "a compound (list) value routed :pinned raises pointing at the scalar-only contract" do
      # `Mutare.Test.CompoundPinnedMutator` routes the `ids: [1, 2]` value :pinned, but pinning
      # `^`-wraps only the value node's own selector — the inner `1`/`2` mutations would emit as
      # bare selectors and poison the DSL. `Analyze.reject_non_scalar_pinned!/2` raises rather than
      # silently degrading them to :poisoned.
      source = """
      defmodule Mutare.CompoundPinnedFixture do
        import Mutare.Test.HostDSL

        def assign(q) do
          set(q, ids: [1, 2])
        end
      end
      """

      assert_raise ArgumentError, ~r/:pinned.*scalar.*compound/s, fn ->
        Mutare.transform_string(source,
          file: "cp.ex",
          mutators: [:literal, Mutare.Test.CompoundPinnedMutator]
        )
      end
    end

    test "a scalar value routed :pinned still pins normally (no false rejection)" do
      # Regression: the scalar pinned path is unaffected — the value's mutation sits on its own
      # node, so there is no descendant candidate and pinning proceeds.
      source = """
      defmodule Mutare.ScalarPinnedFixture do
        import Mutare.Test.HostDSL

        def assign(q) do
          set(q, name: "keep")
        end
      end
      """

      {_meta, sites, _next} =
        Mutare.transform_string(source,
          file: "sp.ex",
          mutators: [:string, Mutare.Test.CompoundPinnedMutator]
        )

      assert Enum.any?(sites, &(&1.mutator == :string and &1.mutated_code == "\"\""))
    end

    test "a bare list argument routed :pinned (not a wrapped keyword value) is also rejected" do
      # `Mutare.Test.ArgPinnedMutator` routes `filter`'s first argument — the bare list `[:foo]` —
      # :pinned. The list has no own candidate, so the `:foo` mutation sits on a descendant that
      # pinning would miss; the bare-list descent in `reject_non_scalar_pinned!/2` catches it.
      source = """
      defmodule Mutare.ArgPinnedFixture do
        import Mutare.Test.HostDSL

        def f(x) do
          filter([:foo], x > 1)
        end
      end
      """

      assert_raise ArgumentError, ~r/:pinned.*scalar.*compound/s, fn ->
        Mutare.transform_string(source,
          file: "ap.ex",
          mutators: [:atom, Mutare.Test.ArgPinnedMutator]
        )
      end
    end
  end

  describe "host-target normalization fails loud on malformed targets" do
    alias Mutare.Mutator.Dispatch
    alias Mutare.Mutator.Spec

    defp malformed_spec do
      %Spec{
        module: Mutare.Test.MalformedHost,
        name: :malformed,
        opts: [],
        behaviours: MapSet.new()
      }
    end

    test "a non-1-arity :wrap raises (not a raw FunctionClauseError)" do
      assert_raise ArgumentError, ~r/:wrap must be a 1-arity function/, fn ->
        Dispatch.host_targets(malformed_spec(), {:bad_wrap, [], []}, %{pipe_mode: :unpiped})
      end
    end

    test "a non-string mutant :note raises (not a silently dropped note)" do
      assert_raise ArgumentError, ~r/:note must be a string or nil/, fn ->
        Dispatch.host_targets(malformed_spec(), {:bad_note, [], []}, %{pipe_mode: :unpiped})
      end
    end

    test "a bare %{node:, note:} map mutant raises (the struct is required)" do
      assert_raise ArgumentError,
                   ~r/must be a %Mutare.Mutator.Mutation\{\}, not a bare map/,
                   fn ->
                     Dispatch.host_targets(malformed_spec(), {:bare_map, [], []}, %{
                       pipe_mode: :unpiped
                     })
                   end
    end
  end
end
