defmodule Mutare.UsesTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.{Imports, Resolve, Uses}

  # The directives `Mutare.Transform.Uses` harvested onto every `use` node, flattened.
  defp directives_at(source) do
    {_ast, acc} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate()
      |> Macro.prewalk([], fn
        {:use, meta, _} = node, acc when is_list(meta) -> {node, acc ++ Uses.directives(meta)}
        node, acc -> {node, acc}
      end)

    acc
  end

  # `%{fun => {module, :bare | :qualify}}` for every bare call resolved through the full
  # pre-pass (Uses → Resolve), the contract the call-matching mutators read.
  defp resolved_calls(source) do
    {_ast, calls} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate()
      |> Resolve.annotate()
      |> Macro.prewalk(%{}, fn
        {fun, meta, args} = node, acc when is_atom(fun) and is_list(args) ->
          case Imports.resolved_import(meta) do
            nil -> {node, acc}
            import_ -> {node, Map.put(acc, fun, import_)}
          end

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # The resolution stamped on every `reject` call, in document order — to show scoping (a
  # using module's call resolves; a sibling without the `use` does not).
  defp reject_resolutions(source) do
    {_ast, acc} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate()
      |> Resolve.annotate()
      |> Macro.prewalk([], fn
        {:reject, meta, args} = node, acc when is_list(args) ->
          {node, [Imports.resolved_import(meta) | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp assert_compiles(meta) do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert [_ | _] = Code.compile_string(meta)
    end)
  end

  describe "harvesting directives (Uses.annotate)" do
    test "stamps the import and alias a static `use` injects" do
      source = """
      defmodule UsesController do
        use Mutare.Test.ControllerUsing

        def f(xs), do: reject(xs, & &1)
      end
      """

      directives = directives_at(source)
      rendered = Enum.map(directives, &Macro.to_string/1)

      assert "import Enum, only: [reject: 2]" in rendered
      assert "alias String, as: S" in rendered
    end

    test "a `use` with no opts expands" do
      source = """
      defmodule UsesSchemaOnly do
        use Mutare.Test.SchemaUsing
      end
      """

      assert Enum.map(directives_at(source), &Macro.to_string/1) == [
               "import Mutare.Test.SchemaDSL"
             ]
    end

    test "flattens nested `use`s transitively" do
      source = """
      defmodule UsesNested do
        use Mutare.Test.NestedUsing
      end
      """

      rendered = Enum.map(directives_at(source), &Macro.to_string/1)
      assert "import Enum, only: [reject: 2]" in rendered
      assert "alias String, as: S" in rendered
    end
  end

  describe "the static-args gate and graceful degradation" do
    test "a `use` with a non-literal argument is skipped" do
      source = """
      defmodule UsesDynamic do
        use Mutare.Test.ControllerUsing, some_var
      end
      """

      assert directives_at(source) == []
    end

    test "an unloadable `use` module degrades to no directives, never raising" do
      source = """
      defmodule UsesMissing do
        use Definitely.Not.Loaded.Anywhere, :controller
      end
      """

      assert directives_at(source) == []
    end

    test "a `__using__` that raises degrades to no directives" do
      source = """
      defmodule UsesRaising do
        use Mutare.Test.RaisingUsing
      end
      """

      assert directives_at(source) == []
    end

    test "a `use`-cycle terminates" do
      source = """
      defmodule UsesCyclic do
        use Mutare.Test.CyclicUsingA
      end
      """

      # The seen-set breaks the A→B→A cycle: it returns (no directives) rather than looping.
      assert directives_at(source) == []
    end

    test "a `use` re-dispatching to the same module with new options is not a cycle" do
      source = """
      defmodule UsesOptionDispatch do
        use Mutare.Test.OptionDispatch, :a
      end
      """

      # `use …, :a` expands to `use …, :b`; the `{module, options}` cycle key lets the distinct
      # `:b` clause expand (a module-only key would drop it as a cycle).
      assert Enum.map(directives_at(source), &Macro.to_string/1) == ["import Map, only: [pop: 2]"]
    end
  end

  describe "expansion scope (quoted data and unresolvable modules)" do
    test "a `use` inside a `quote` (quoted data, not a real directive) is not expanded" do
      source = """
      defmodule UsesInQuote do
        defmacro gen do
          quote do
            defmodule Inner do
              use Mutare.Test.ControllerUsing
            end
          end
        end
      end
      """

      # The `defmodule … use …` only becomes a real module when the quote is expanded in some
      # caller's context — invoking `__using__` during the scan would run it in the wrong context.
      assert directives_at(source) == []
    end

    test "a `use` in a statically-named nested module still expands (regression guard)" do
      source = """
      defmodule Outer do
        defmodule Inner do
          use Mutare.Test.ControllerUsing
        end
      end
      """

      assert "import Enum, only: [reject: 2]" in Enum.map(
               directives_at(source),
               &Macro.to_string/1
             )
    end

    test "a `use` in a non-statically-named nested module (`__MODULE__.Child`) is skipped" do
      source = """
      defmodule UsesDynamicChild do
        defmodule __MODULE__.Child do
          use Mutare.Test.ControllerUsing
        end
      end
      """

      # The child's concrete name is unknown, so expanding would pass the *parent* as
      # `__CALLER__.module` and stamp directives for the wrong namespace — skip instead.
      assert directives_at(source) == []
    end
  end

  describe "aliased `use` targets" do
    test "an aliased target is resolved to the real module before expansion" do
      source = """
      defmodule UsesAliasedTarget do
        alias Mutare.Test.ControllerUsing, as: Ctrl
        use Ctrl
      end
      """

      # `use Ctrl` expands `Mutare.Test.ControllerUsing` (the alias target), not a literal `Ctrl`
      # (which isn't loadable — the old, unresolved behaviour degraded to no directives here).
      assert "import Enum, only: [reject: 2]" in Enum.map(
               directives_at(source),
               &Macro.to_string/1
             )
    end

    test "the real target wins over a same-named loadable decoy" do
      source = """
      defmodule UsesAliasedDecoy do
        alias Mutare.Test.ControllerUsing, as: MutareUseAliasDecoy
        use MutareUseAliasDecoy
      end
      """

      rendered = Enum.map(directives_at(source), &Macro.to_string/1)

      # The compiler would expand `ControllerUsing.__using__` (the alias target); without
      # resolution we'd wrongly expand the loadable same-named `MutareUseAliasDecoy` instead.
      assert "import Enum, only: [reject: 2]" in rendered
      refute "import Enum, only: [filter: 2]" in rendered
    end

    test "an alias does not leak to a `use` written above it" do
      source = """
      defmodule UseBeforeAlias do
        use Ctrl
        alias Mutare.Test.ControllerUsing, as: Ctrl
      end
      """

      # `use Ctrl` precedes the alias, so `Ctrl` is unresolved (and unloadable) ⇒ no directives.
      assert directives_at(source) == []
    end

    test "an alias injected by an earlier `use` resolves a later `use` target" do
      source = """
      defmodule UsesInjectedAlias do
        use Mutare.Test.AliasInjector
        use T
      end
      """

      rendered = Enum.map(directives_at(source), &Macro.to_string/1)

      # `use AliasInjector` injects `alias RealTarget, as: T`; the later `use T` must expand
      # `RealTarget` through it (Elixir does), surfacing RealTarget's `import Map, only: [get: 2]`.
      assert "alias Mutare.Test.RealTarget, as: T" in rendered
      assert "import Map, only: [get: 2]" in rendered
    end

    test "an alias declared inside a `__using__` body resolves a sibling `use`" do
      source = """
      defmodule UsesBodyAlias do
        use Mutare.Test.BodyAliasUsing
      end
      """

      rendered = Enum.map(directives_at(source), &Macro.to_string/1)

      # The expanded body is `alias BodyAliasTarget, as: T; use T`; the nested `use T` must resolve
      # through that in-body alias, surfacing BodyAliasTarget's `import Map, only: [merge: 2]`.
      assert "alias Mutare.Test.BodyAliasTarget, as: T" in rendered
      assert "import Map, only: [merge: 2]" in rendered
    end

    test "an alias a nested `use` injects resolves a later sibling `use` in the same body" do
      source = """
      defmodule UsesNestedInject do
        use Mutare.Test.NestedInjectUsing
      end
      """

      rendered = Enum.map(directives_at(source), &Macro.to_string/1)

      # The body is `use AliasInjector; use T`: the first nested `use` injects `alias RealTarget,
      # as: T`, which the later `use T` resolves through — surfacing `import Map, only: [get: 2]`.
      assert "alias Mutare.Test.RealTarget, as: T" in rendered
      assert "import Map, only: [get: 2]" in rendered
    end

    test "a top-level alias resolves a `use` in a following `defmodule`" do
      source = """
      alias Mutare.Test.ControllerUsing, as: U

      defmodule TopAliasMod do
        use U
      end
      """

      # A multi-form file is a `:__block__`; the top-level alias scopes into the following module
      # (the compiler expands `use U` as `ControllerUsing.__using__`), so its import is surfaced.
      assert "import Enum, only: [reject: 2]" in Enum.map(
               directives_at(source),
               &Macro.to_string/1
             )
    end
  end

  describe "nested-module naming (caller passed to `__using__`)" do
    test "a nested `Elixir.*` head is treated as absolute, not prefixed by the parent" do
      source = """
      defmodule Outer do
        defmodule Elixir.MutareCallerBar do
          use Mutare.Test.CallerProbe
        end
      end
      """

      # `defmodule Elixir.MutareCallerBar` defines the absolute `MutareCallerBar`, so the caller
      # passed to `__using__` is `MutareCallerBar` — never `Outer.Elixir.MutareCallerBar`.
      assert Enum.map(directives_at(source), &Macro.to_string/1) == [
               "alias MutareCallerBar, as: TheCaller"
             ]
    end

    test "an ordinary nested module is prefixed by its parent (regression guard)" do
      source = """
      defmodule OuterReg do
        defmodule Inner do
          use Mutare.Test.CallerProbe
        end
      end
      """

      assert Enum.map(directives_at(source), &Macro.to_string/1) == [
               "alias OuterReg.Inner, as: TheCaller"
             ]
    end

    test "a top-level aliased head is resolved through the alias for the caller" do
      source = """
      alias RealParent, as: RP

      defmodule RP.Child do
        use Mutare.Test.CallerProbe
      end
      """

      # Top-level `defmodule RP.Child` (with `RP` aliased) defines `RealParent.Child`, so the
      # caller passed to `__using__` is `RealParent.Child` — not the literal `RP.Child`.
      assert Enum.map(directives_at(source), &Macro.to_string/1) == [
               "alias RealParent.Child, as: TheCaller"
             ]
    end
  end

  describe "resolution through the injected directives" do
    test "an injected import makes a bare stdlib call resolve" do
      source = """
      defmodule ResolvesReject do
        use Mutare.Test.ControllerUsing

        def f(xs), do: reject(xs, & &1)
      end
      """

      assert resolved_calls(source)[:reject] == {[:Enum], :qualify}
    end

    test "without expansion the same call is unresolved" do
      source = """
      defmodule UnresolvedReject do
        use Mutare.Test.ControllerUsing

        def f(xs), do: reject(xs, & &1)
      end
      """

      # No `Uses.annotate` — straight to `Resolve`, mirroring `expand_uses: false`.
      {_ast, calls} =
        source
        |> Sourceror.parse_string!()
        |> Resolve.annotate()
        |> Macro.prewalk(%{}, fn
          {fun, meta, args} = node, acc when is_atom(fun) and is_list(args) ->
            case Imports.resolved_import(meta) do
              nil -> {node, acc}
              import_ -> {node, Map.put(acc, fun, import_)}
            end

          node, acc ->
            {node, acc}
        end)

      assert calls[:reject] == nil
    end

    test "a `use` injected into a nested module does not leak to a sibling" do
      source = """
      defmodule UsingMod do
        use Mutare.Test.ControllerUsing
        def g(xs), do: reject(xs, & &1)
      end

      defmodule PlainMod do
        def h(xs), do: reject(xs, & &1)
      end
      """

      # One `reject` resolves (the using module), one stays unresolved (the sibling).
      resolutions = reject_resolutions(source)
      assert {[:Enum], :qualify} in resolutions
      assert nil in resolutions
    end
  end

  describe "end-to-end: missed mutants (pain 1)" do
    @controller_source """
    defmodule MutatedController do
      use Mutare.Test.ControllerUsing

      def f(xs), do: reject(xs, & &1)
    end
    """

    test "a call relying on a use-injected import now produces mutants" do
      {meta, sites, _next_id} =
        Mutare.transform_string(@controller_source, mutators: [Mutare.Mutators.Collection])

      assert Enum.any?(sites, &(&1.mutator == :collection))
      assert_compiles(meta)
    end

    test "with :expand_uses false, the call is invisible and yields no mutant" do
      {_meta, sites, _next_id} =
        Mutare.transform_string(@controller_source,
          mutators: [Mutare.Mutators.Collection],
          expand_uses: false
        )

      assert sites == []
    end
  end

  describe "end-to-end: the Ecto :skip case (pain 2)" do
    @schema_source """
    defmodule UsesSchemaViaUse do
      use Mutare.Test.SchemaUsing

      schema do
        field(:age, default: 1 + 1)
      end
    end
    """

    @schema_mutators [
      Mutare.Mutators.Arithmetic,
      Mutare.Mutators.Literal,
      Mutare.Mutators.AtomLiteral
    ]

    test "the use-injected import makes the registered :skip macro fire" do
      {meta, sites, _next_id} =
        Mutare.transform_string(@schema_source,
          mutators: @schema_mutators,
          macros: [{Mutare.Test.SchemaDSL, :schema, 1, :skip}]
        )

      # `schema` resolves to `Mutare.Test.SchemaDSL` only because the `use` injected its import,
      # so the `:skip` routing keeps core out of the DSL body.
      assert sites == []
      assert_compiles(meta)
    end

    test "with :expand_uses false the import is invisible, so the :skip is dead and core mutates" do
      {_meta, sites, _next_id} =
        Mutare.transform_string(@schema_source,
          mutators: @schema_mutators,
          macros: [{Mutare.Test.SchemaDSL, :schema, 1, :skip}],
          expand_uses: false
        )

      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
    end
  end

  describe "the stamp never reaches the rendered metamutant" do
    test "directives are stripped before render" do
      {meta, _sites, _next_id} =
        Mutare.transform_string(@controller_source, mutators: [Mutare.Mutators.Collection])

      refute meta =~ "mutare_use_directives"
    end
  end
end
