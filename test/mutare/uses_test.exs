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

  # The behaviour modules `Mutare.Transform.Uses` harvested onto every `use` node, flattened.
  defp behaviours_at(source) do
    {_ast, acc} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate()
      |> Macro.prewalk([], fn
        {:use, meta, _} = node, acc when is_list(meta) ->
          {node, acc ++ Uses.injected_behaviours(meta)}

        node, acc ->
          {node, acc}
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
    assert [_ | _] = Mutare.Test.Compile.string(meta)
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

    test "a raising *nested* `use` drops only its own contribution, not its siblings" do
      # The bundle's `__using__` body mixes good directives with a nested raiser, mirroring an
      # idiomatic Phoenix `:live_view` that contains `use Gettext, backend: …` (whose `__using__`
      # mutates the caller and raises). The raise must be isolated to that one `use`.
      source = """
      defmodule UsesBundleWithRaiser do
        use Mutare.Test.BundleWithRaisingUsing
      end
      """

      rendered = Enum.map(directives_at(source), &Macro.to_string/1)

      # The good siblings, on either side of the raiser in the bundle block, survive.
      assert "import Enum, only: [reject: 2]" in rendered
      assert behaviours_at(source) == [Mutare.Test.SampleBehaviour]

      # The raiser's own injected directive never expanded, so it (alone) is dropped.
      refute "import Map, only: [take: 2]" in rendered
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

    test "a `require Mod, as: U` (which also aliases) resolves a later `use U`" do
      source = """
      defmodule UsesRequireAlias do
        require Mutare.Test.ControllerUsing, as: U
        use U
      end
      """

      # `require Mod, as: U` introduces the alias `U`, just like `alias` — so `use U` must expand
      # `ControllerUsing` through it.
      assert "import Enum, only: [reject: 2]" in Enum.map(
               directives_at(source),
               &Macro.to_string/1
             )
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

    test "an `unquote`d-target alias in a `__using__` body resolves a sibling `use`" do
      source = """
      defmodule UsesUnquoteAlias do
        use Mutare.Test.UnquoteAliasUsing
      end
      """

      rendered = Enum.map(directives_at(source), &Macro.to_string/1)

      # The expanded body is `alias unquote(BodyAliasTarget), as: T; use T`, where `unquote` splices
      # the target as a *bare atom*. The harvested alias must be normalized before being folded into
      # the body env, else `T` stays unbound and `use T` is dropped — so `merge` would be missing.
      assert "alias Mutare.Test.BodyAliasTarget, as: T" in rendered
      assert "import Map, only: [merge: 2]" in rendered
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

    test "a caller alias is visible to `__using__` via `__CALLER__.aliases`" do
      source = """
      defmodule UsesCallerAliases do
        alias Enum, as: U
        use Mutare.Test.AliasAwareUsing
      end
      """

      rendered = Enum.map(directives_at(source), &Macro.to_string/1)

      # `AliasAwareUsing.__using__` branches on whether the caller aliased anything to `Enum`. The
      # real compiler sees `alias Enum, as: U`, so it injects the `fetch` import; the pre-pass must
      # mirror the source alias env into the expansion `Macro.Env`, not leave its own (which never
      # aliases `Enum`) — otherwise it would harvest the wrong fallback (`get`).
      assert "import Map, only: [fetch: 2]" in rendered
      refute "import Map, only: [get: 2]" in rendered
    end

    test "without a caller alias `__using__` takes its `__CALLER__.aliases` fallback" do
      source = """
      defmodule UsesNoCallerAlias do
        use Mutare.Test.AliasAwareUsing
      end
      """

      rendered = Enum.map(directives_at(source), &Macro.to_string/1)

      # No `alias Enum`, so `__CALLER__.aliases` doesn't mention `Enum` and the fallback (`get`)
      # branch fires — confirming the env isn't accidentally carrying Mutare's own aliases.
      assert "import Map, only: [get: 2]" in rendered
      refute "import Map, only: [fetch: 2]" in rendered
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

    test "a `use` inside an atom-named module (`defmodule :foo`) is expanded" do
      source = """
      defmodule :mutare_atom_mod do
        use Mutare.Test.ControllerUsing
      end
      """

      # Sourceror wraps the atom head as `{:__block__, _, [:mutare_atom_mod]}` — the module is the
      # atom itself, so the `use` inside must still be stamped (its import surfaced).
      assert "import Enum, only: [reject: 2]" in Enum.map(
               directives_at(source),
               &Macro.to_string/1
             )
    end
  end

  describe "implicit aliases from sibling-defined nested modules" do
    test "a `defimpl` of a sibling-defined protocol computes the parent-qualified caller" do
      source = """
      defmodule MutareNestedProto do
        defprotocol P do
          def f(x)
        end

        defimpl P, for: Integer do
          use Mutare.Test.CallerProbe
        end
      end
      """

      # Inside `MutareNestedProto`, `defprotocol P` defines `MutareNestedProto.P` and Elixir
      # auto-aliases `P => MutareNestedProto.P`. So `defimpl P, for: Integer` opens module
      # `MutareNestedProto.P.Integer` — the caller passed to `__using__`. Without mirroring that
      # implicit alias the pass resolved `P` to itself and computed the wrong caller `P.Integer`.
      assert Enum.map(directives_at(source), &Macro.to_string/1) == [
               "alias MutareNestedProto.P.Integer, as: TheCaller"
             ]
    end

    test "a `use` of a sibling-defined module by short name resolves and stamps" do
      source = """
      defmodule Mutare.Test do
        defmodule ControllerUsing do
        end

        use ControllerUsing
      end
      """

      # `defmodule ControllerUsing` nested in `Mutare.Test` auto-aliases `ControllerUsing =>
      # Mutare.Test.ControllerUsing` (the real loaded fixture), so the short-name `use
      # ControllerUsing` resolves to it and its directives surface. Without the implicit alias,
      # `ControllerUsing` resolves to the unloadable top-level `ControllerUsing` ⇒ unstamped.
      rendered = Enum.map(directives_at(source), &Macro.to_string/1)
      assert "import Enum, only: [reject: 2]" in rendered
      assert "alias String, as: S" in rendered
    end

    test "a nested module head's own implicit alias is in scope inside its body" do
      source = """
      defmodule Mutare.Test do
        defmodule HeadAlias.Bar do
          use HeadAlias.Target
        end
      end
      """

      # Inside `HeadAlias.Bar` (full name `Mutare.Test.HeadAlias.Bar`), the head's own implicit
      # alias `HeadAlias => Mutare.Test.HeadAlias` is in scope, so `use HeadAlias.Target` resolves
      # to the real `Mutare.Test.HeadAlias.Target` fixture. Passing only the parent env would leave
      # `HeadAlias` unbound and the `use` unstamped.
      assert "import Map, only: [merge: 2]" in Enum.map(directives_at(source), &Macro.to_string/1)
    end

    test "the implicit alias scopes only to following siblings (not the definition itself)" do
      source = """
      defmodule MutareImplicitScope do
        use P
        defprotocol P do
          def f(x)
        end
      end
      """

      # `use P` precedes `defprotocol P`, so the implicit `P => MutareImplicitScope.P` alias isn't
      # in scope yet; `P` is unresolved/unloadable ⇒ no directives (lexical, like an explicit alias).
      assert directives_at(source) == []
    end
  end

  describe "module-defining forms (defimpl / defprotocol)" do
    test "a `use` inside a `defimpl` is expanded (import surfaced, calls resolve)" do
      source = """
      defimpl Mutare.Test.SomeProto, for: Integer do
        use Mutare.Test.ControllerUsing
        def f(x), do: reject([x], & &1)
      end
      """

      # `defimpl P, for: Integer` opens module `P.Integer`; the direct `use` must be stamped so the
      # injected import is visible and the bare `reject` resolves to `Enum`.
      assert "import Enum, only: [reject: 2]" in Enum.map(
               directives_at(source),
               &Macro.to_string/1
             )

      assert resolved_calls(source)[:reject] == {[:Enum], :qualify}
    end

    test "a `defimpl` with a list `for:` is skipped (impl module ambiguous)" do
      source = """
      defimpl Mutare.Test.SomeProto, for: [Integer, Float] do
        use Mutare.Test.ControllerUsing
      end
      """

      # Two impl modules — the caller is ambiguous, so we conservatively don't stamp.
      assert directives_at(source) == []
    end

    test "a `use` inside a `defprotocol` is expanded" do
      source = """
      defprotocol Mutare.Test.SomeProto do
        use Mutare.Test.ControllerUsing
      end
      """

      assert "import Enum, only: [reject: 2]" in Enum.map(
               directives_at(source),
               &Macro.to_string/1
             )
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
        Mutare.Transform.transform_string_with_sites(@controller_source,
          mutators: [Mutare.Mutators.Collection]
        )

      assert Enum.any?(sites, &(&1.mutator == :collection))
      assert_compiles(meta)
    end

    test "with :expand_uses false, the call is invisible and yields no mutant" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@controller_source,
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
        Mutare.Transform.transform_string_with_sites(@schema_source,
          mutators: @schema_mutators,
          macro_routes: [{Mutare.Test.SchemaDSL, :schema, 1, :skip}]
        )

      # `schema` resolves to `Mutare.Test.SchemaDSL` only because the `use` injected its import,
      # so the `:skip` routing keeps core out of the DSL body.
      assert sites == []
      assert_compiles(meta)
    end

    test "with :expand_uses false the import is invisible, so the :skip is dead and core mutates" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@schema_source,
          mutators: @schema_mutators,
          macro_routes: [{Mutare.Test.SchemaDSL, :schema, 1, :skip}],
          expand_uses: false
        )

      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
    end
  end

  describe "the stamp never reaches the rendered metamutant" do
    test "directives are stripped before render" do
      {meta, _sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@controller_source,
          mutators: [Mutare.Mutators.Collection]
        )

      refute meta =~ "mutare_use_directives"
    end

    test "the degraded-use stamp is stripped before render" do
      {meta, _sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule M do\n  use Definitely.Not.Loaded, :x\n  def f, do: 1 + 1\nend\n",
          mutators: [Mutare.Mutators.Arithmetic]
        )

      refute meta =~ "mutare_use_degraded"
    end
  end

  describe "degraded_uses/2 (the --check diagnostic)" do
    defp degraded(source), do: source |> Sourceror.parse_string!() |> Uses.degraded_uses()

    test "flags an unloadable module-level `use` with :not_loadable and its line" do
      source = """
      defmodule UsesMissing do
        use Definitely.Not.Loaded.Anywhere, :controller
      end
      """

      assert [%{module: Definitely.Not.Loaded.Anywhere, reason: :not_loadable, line: 2}] =
               degraded(source)
    end

    test "flags a non-literal-argument `use` with :nonstatic_args" do
      source = """
      defmodule UsesDynamic do
        use Mutare.Test.ControllerUsing, some_var
      end
      """

      assert [%{module: Mutare.Test.ControllerUsing, reason: :nonstatic_args}] = degraded(source)
    end

    test "does NOT flag a `use` that expands cleanly (an empty expand is not a degradation)" do
      source = """
      defmodule UsesController do
        use Mutare.Test.ControllerUsing
      end
      """

      assert degraded(source) == []
    end

    test "does NOT flag a `use` nested inside a def (not a module-level directive)" do
      source = """
      defmodule NotModuleLevel do
        def f do
          use Definitely.Not.Loaded.Anywhere
        end
      end
      """

      assert degraded(source) == []
    end

    test "a raising __using__ is not flagged (indistinguishable from an empty expand)" do
      # The pre-expansion gates (loadable + static args) both pass, so this is treated as a
      # clean-but-empty expand, not a reportable degradation — the extension-covered case.
      source = """
      defmodule UsesRaising do
        use Mutare.Test.RaisingUsing
      end
      """

      assert degraded(source) == []
    end
  end
end
