defmodule Mutare.TransformCallRoutingTest do
  # Known-macro argument routing: match?/destructure pattern context, registered macros
  # (`:call_routes` / a mutator's `call_routes/0`), and a piped value reaching the macro's effective
  # position-0 treatment. Split from transform_test.exs.
  use ExUnit.Case, async: true
  import Mutare.Test.Metamutant

  # Pin context-routing probes to the two operator-swap families (stable site counts).
  @probe [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  describe "match?/2 pattern-context routing" do
    test "the first arg is a pattern (literals there are not mutated); the matched expr is runtime" do
      source = """
      defmodule MatchQ do
        def f(s, n) do
          match?("x" <> _, s) and n + 1 > 0
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: @probe ++ [Mutare.Mutators.StringLiteral]
        )

      # The string `"x"` lives in the `match?` pattern, so it is never offered to a
      # mutator (splicing a selector there is "case not allowed in matches"). The
      # runtime `n + 1`/`> 0` around it still mutate.
      assert Enum.frequencies_by(sites, & &1.mutator) == %{arithmetic: 1, relational: 2}
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a literal inside a tuple pattern in match? is still not mutated" do
      source = """
      defmodule MatchTuple do
        def f(pair), do: match?({"_" <> _v, _m}, pair)
      end
      """

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringLiteral, Mutare.Mutators.TupleLiteral]
        )

      # No string-empty/tuple-empty mutation reaches the match? pattern.
      assert sites == []
    end

    test "a qualified Kernel.match?/2 is pattern-routed too (resolution, not bare name)" do
      source = """
      defmodule QualMatch do
        def f(s), do: Kernel.match?("x" <> _, s)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringLiteral]
        )

      # The old hard-coded clause matched only the bare `match?`; the registry resolves
      # `Kernel.match?` so the qualified form's pattern arg is left unmutated too.
      assert sites == []
      assert {:ok, _} = Code.string_to_quoted(meta)
    end
  end

  describe "Kernel.destructure/2 is a built-in known macro" do
    test "the first arg is a pattern (a literal there is not mutated)" do
      source = """
      defmodule Destr do
        def f(list) do
          destructure([a, b, 0], list)
          a + b
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.IntegerLiteral]
        )

      # The `0` in destructure's first (pattern) arg is never offered; the runtime
      # `a + b` still mutates (arithmetic). No literal mutant from the pattern.
      assert Enum.frequencies_by(sites, & &1.mutator) == %{arithmetic: 1}
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "an escaping binding macro in a nested quote option prunes unsafe unquote ancestors" do
      source = """
      defmodule QuoteOptionBinding do
        def run(y) do
          quote do
            unquote(
              [quote do
                 quote line: unquote(destructure([x], List.wrap(y))) do
                   :generated
                 end
               end] ++ []
            )
          end

          x
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.List])

      # The line: option value stays unmutated, but Resolve must still stamp the escaping
      # destructure/2 there. The live-unquote binding-prune pass then sees that x escapes and
      # drops the unsafe ancestor ++ selector; otherwise the baseline branch traps x inside a
      # case and the metamutant fails to compile.
      assert sites == []
      assert_compiles(meta)
    end
  end

  describe "registered macros (`:call_routes` / a mutator's `call_routes/0`)" do
    @query_source """
    defmodule UsesQuery do
      import Mutare.Test.QueryDSL

      def run(y) do
        query(where: 1 == y, select: 2)
      end
    end
    """

    test "without registration, core mutates inside the macro's argument" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@query_source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral]
        )

      # The DSL body is just a call argument here — `1 == y` and the literals mutate.
      assert Enum.any?(sites, &(&1.mutator == :relational))
      assert Enum.any?(sites, &(&1.mutator == :integer))
    end

    test "a `:skip` macro from a mutator's call_routes/0 keeps core out and lets the mutator fire" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@query_source,
          mutators: [
            Mutare.Mutators.Relational,
            Mutare.Mutators.IntegerLiteral,
            Mutare.Test.QueryMutator
          ]
        )

      # Core leaves the opaque DSL body alone (no relational/literal sites), while the
      # macro-aware mutator drops the last clause — its registration rode in via call_routes/0.
      assert Enum.map(sites, & &1.mutator) == [:query_dsl]
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a declarative `:call_routes` `:skip` entry suppresses core with no custom mutator" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@query_source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Mutare.Test.QueryDSL, :query, 1, :raw}]
        )

      # The DSL body is skipped; with no mutator registered for it, nothing mutates.
      assert sites == []
    end

    @wide_query_source """
    defmodule UsesQueryWide do
      import Mutare.Test.QueryDSL

      def run(y) do
        query(where: 1 == y, select: 2)
      end

      def filter(q, y) do
        q |> where(1 == y)
      end
    end
    """

    test "a whole-module `:*` entry skips every macro in the module" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@wide_query_source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Mutare.Test.QueryDSL, :*, :raw}]
        )

      # Both `query(...)` and the piped `where(...)` are macros in QueryDSL, so the
      # whole-module entry leaves all their arguments raw — nothing in either mutates.
      assert sites == []
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a more specific entry overrides the whole-module `:*` (per-macro override)" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@wide_query_source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral],
          call_routes: [
            {Mutare.Test.QueryDSL, :*, :raw},
            {Mutare.Test.QueryDSL, :where, 2, [:expression, :expression]}
          ]
        )

      # `query(...)` stays skipped (whole-module), but `where/2` is overridden to mutate its
      # args — so only the piped `1 == y` produces relational + literal sites (the identical
      # `1 == y` *inside* the skipped `query(...)` keyword stays raw).
      assert Enum.any?(sites, &(&1.mutator == :relational))
      assert Enum.any?(sites, &(&1.mutator == :integer))
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a name-only `{:*, name, ...}` entry skips the macro regardless of module" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@query_source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral],
          call_routes: [{:*, :query, :raw}]
        )

      # No module is named in the entry, yet `query(...)` (which resolves to QueryDSL) is
      # skipped — the name-only escape hatch matches the macro in any module.
      assert sites == []
    end

    test "a known macro drops the bare-import witness (it can't reconstruct the call)" do
      # The import witness reconstructs a bare-imported call as a dead-code `fn a -> query(a) end`
      # to prove it still resolves to the believed provider. For a known macro that constrains its
      # arguments — `Ecto.Query.from/2` needs a compile-time keyword list — that reconstruction would
      # not compile, poisoning the build for *every* mutation of an expression containing the call. So
      # a registered macro keeps its resolution stamp (for `Calls`) but drops the witness. (`query/1`
      # is the importable stand-in here; the real failure mode it guards against is `Ecto.Query.from`.)
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@query_source,
          mutators: [Mutare.Test.QueryMutator]
        )

      assert Enum.map(sites, & &1.mutator) == [:query_dsl]
      refute meta =~ "import Elixir.Mutare.Test.QueryDSL"
    end

    @piped_source """
    defmodule PipedQuery do
      import Mutare.Test.QueryDSL

      def run(q, y) do
        q |> where(1 == y)
      end
    end
    """

    test "a piped macro stage is routed too (effective arity, visible routing)" do
      # `q |> where(1 == y)` is `where(q, 1 == y)` — effective arity 2 matches the
      # registered `where/2`; the condition (the macro's second/`:skip` arg) is left raw,
      # so core never mutates `1 == y` even though it is a *piped* stage.
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@piped_source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Mutare.Test.QueryDSL, :where, 2, [:expression, :raw]}]
        )

      assert sites == []
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "without the registration, a piped stage's body still mutates (the skip is doing the work)" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@piped_source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral]
        )

      # `1 == y` and the `1` literal mutate when `where` is just an ordinary piped call.
      assert Enum.any?(sites, &(&1.mutator == :relational))
      assert Enum.any?(sites, &(&1.mutator == :integer))
    end

    @schema_source """
    defmodule UsesSchema do
      import Mutare.Test.SchemaDSL

      schema do
        field(:age, default: 1 + 1)
      end
    end
    """

    @schema_mutators [
      Mutare.Mutators.Arithmetic,
      Mutare.Mutators.IntegerLiteral,
      Mutare.Mutators.AtomLiteral
    ]

    test "a `:skip` module-level macro block is left raw (the analyze_module_macro_block path)" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@schema_source,
          mutators: @schema_mutators,
          call_routes: [{Mutare.Test.SchemaDSL, :schema, 1, :raw}]
        )

      # `schema do … end` is a *module-level* macro-with-block, routed through
      # `analyze_module_macro_block/2`, not the generic runtime clause. Its `do` body is an
      # opaque DSL (`:age`/`default:`/`1 + 1` are DSL syntax, not runtime values), so the
      # `:skip` stamp must keep core out — otherwise core's "a block body may be unquoted
      # into a function" guess mutates the DSL and can poison it.
      assert sites == []
      assert_compiles(meta)
    end

    test "without the registration, core mutates inside the module-level block body" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@schema_source, mutators: @schema_mutators)

      # The unknown-macro default analyzes a block body as runtime, so the DSL body's
      # literals/operators mutate — exactly what the `:skip` registration prevents.
      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      assert Enum.any?(sites, &(&1.mutator == :atom))
    end

    test "an unknown block macro tags every body site with its {name, nid} (for poison recovery)" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@schema_source, mutators: @schema_mutators)

      # `schema` is unknown here, so the whole DSL body is mutated and *tagged* —
      # so `Mutare.Runner` can skip the whole block at once if the injected selector
      # poisons the DSL, instead of dropping mutants one at a time. The tag carries the
      # name (for readability) and a per-invocation `nid`.
      assert sites != []
      assert Enum.all?(sites, &match?({:schema, nid} when is_integer(nid), &1.block_macro))
    end

    test "two invocations of the same block macro get distinct per-invocation tags" do
      # The bare name would bucket both `schema do … end`s together, so a poison in one
      # would suppress the other. The `nid` makes the tag per-invocation: each block's
      # sites share a tag, but the two blocks' tags differ — so poison recovery skips one
      # block without touching its same-named sibling.
      source = """
      defmodule Twice do
        import Mutare.Test.SchemaDSL

        schema do
          field(:age, default: 1 + 1)
        end

        schema do
          field(:size, default: 2 + 2)
        end
      end
      """

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @schema_mutators)

      tags = sites |> Enum.map(& &1.block_macro) |> Enum.uniq()

      # Both invocations are `:schema`, but the two blocks carry different nids.
      assert Enum.all?(tags, &match?({:schema, _}, &1))
      assert length(tags) == 2
    end

    test "a registered macro's body sites are left untagged (never auto-skipped)" do
      # Routing the block as `:expression` (mutate) keeps the body mutatable like the
      # unknown default — but because the user *registered* it, the auto-skip-on-poison
      # tag is withheld: their choice to mutate it is honoured.
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@schema_source,
          mutators: @schema_mutators,
          call_routes: [{Mutare.Test.SchemaDSL, :schema, 1, :expression}]
        )

      assert sites != []
      assert Enum.all?(sites, &(&1.block_macro == nil))
    end

    # A DSL module defined *only in the target project* — one the Mutare process can't load —
    # whole-imported. `Imports.stamp` resolves a whole `import Mod` by reflection, which fails
    # for an unloadable module, so the registry must be consulted directly to honour the user's
    # `:call_routes` registration. (`Not.Loadable.Dsl` is a deliberately undefined module.)
    @unloadable_block """
    defmodule UsesUnloadableSchema do
      import Not.Loadable.Dsl

      schema do
        field(:age, default: 1 + 1)
      end
    end
    """

    test "a `:skip` macro via a whole import of an unloadable module is honoured" do
      refute Code.ensure_loaded?(Not.Loadable.Dsl)

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@unloadable_block,
          mutators: @schema_mutators,
          call_routes: [{Not.Loadable.Dsl, :schema, 1, :raw}]
        )

      # The block resolves to the registered macro despite the unloadable module, so its
      # opaque body is left raw — no sites — exactly as for a loadable DSL. (The metamutant
      # can't be compiled here because the DSL module genuinely doesn't exist; the regression
      # is that core no longer *mutates* the opaque body.)
      assert sites == []
    end

    test "a registered macro via an unloadable whole import is classified known (not auto-skipped)" do
      # Routed `:expression` (mutate), the body still mutates — but because the registry
      # resolved it through the unloadable import, it is *known*, so the auto-skip-on-poison
      # tag is withheld. Before the registry fallback it was misclassified as an unknown block
      # macro, and a single poison there dropped every sibling mutant in the block.
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@unloadable_block,
          mutators: @schema_mutators,
          call_routes: [{Not.Loadable.Dsl, :schema, 1, :expression}]
        )

      assert sites != []
      assert Enum.all?(sites, &(&1.block_macro == nil))
    end

    test "without the registration, an unloadable whole-imported block is unknown (mutated + tagged)" do
      # The control: with no `:call_routes` entry the block is genuinely unknown, so its body is
      # mutated on the runtime-body guess and tagged for whole-block poison recovery.
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@unloadable_block,
          mutators: @schema_mutators
        )

      assert sites != []
      assert Enum.all?(sites, &match?({:schema, nid} when is_integer(nid), &1.block_macro))
    end

    test "a `:skip` runtime macro via an unloadable whole import is honoured" do
      # The generic runtime-clause path (not the module-level block): a bare macro call in a
      # function body, reached through an unloadable whole import. The condition is the
      # macro's `:skip` argument, so it must be left raw.
      source = """
      defmodule UsesUnloadableQuery do
        import Not.Loadable.Dsl

        def run(q, y) do
          where(q, 1 == y)
        end
      end
      """

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Not.Loadable.Dsl, :where, 2, [:expression, :raw]}]
        )

      assert sites == []
    end

    test "a selective import of an unloadable module already resolves (no reflection needed)" do
      # The fallback is scoped to whole imports because a selective import resolves straight
      # from the source — this works with or without the fix, and guards that the whole-import
      # restriction doesn't regress the selective case.
      source = """
      defmodule UsesSelectiveUnloadable do
        import Not.Loadable.Dsl, only: [where: 2]

        def run(q, y) do
          where(q, 1 == y)
        end
      end
      """

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Not.Loadable.Dsl, :where, 2, [:expression, :raw]}]
        )

      assert sites == []
    end
  end

  describe "an Erlang/atom-module known macro is routed (direct, piped, aliased)" do
    # An atom-module DSL macro (`:my_dsl.filter(...)`) resolves and routes exactly like an
    # Elixir-module one — the `Mutare.Transform.Resolve` atom-remote walk clause stamps a genuine
    # atom receiver, so a `:skip` registration keeps core out of the argument. `:my_dsl` is a
    # fictitious DSL module (its routing is purely syntactic, no reflection), and the metamutant
    # still compiles (an undefined atom module is a warning, not an error). Each test pairs the
    # `:skip` with a no-registration control, so the empty site list is provably the routing's work.
    @atom_lit [Mutare.Mutators.IntegerLiteral]
    @atom_skip [{:my_dsl, :filter, :any, :raw}]

    test "a direct atom-module `:skip` macro leaves its argument raw" do
      source = """
      defmodule AtomDirect do
        def f(q), do: :my_dsl.filter(q, 99)
      end
      """

      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: @atom_lit,
          call_routes: @atom_skip
        )

      # The `99` lives in a `:skip` argument of the atom-module macro, so it is never offered.
      assert sites == []
      assert_compiles(meta)
    end

    test "a piped atom-module `:skip` macro leaves the piped value raw" do
      source = """
      defmodule AtomPiped do
        def f(q), do: q |> :my_dsl.filter(99)
      end
      """

      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: @atom_lit,
          call_routes: @atom_skip
        )

      # `q |> :my_dsl.filter(99)` is `:my_dsl.filter(q, 99)` — effective arity 2 matches the
      # `:any`-arity registration, so the visible `99` is left raw even as a piped stage.
      assert sites == []
      assert_compiles(meta)
    end

    test "an aliased atom-module `:skip` macro is routed through the alias" do
      source = """
      defmodule AtomAliased do
        alias :my_dsl, as: D
        def f(q), do: D.filter(q, 99)
      end
      """

      {meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: @atom_lit,
          call_routes: @atom_skip
        )

      # `alias :my_dsl, as: D; D.filter(...)` resolves `D` back to `:my_dsl` (the `__aliases__`
      # walk clause), so the registration on `:my_dsl` still routes the call's arg `:skip`.
      assert sites == []
      assert_compiles(meta)
    end

    test "without the registration, the same atom-module argument mutates (routing is doing the work)" do
      source = """
      defmodule AtomNoReg do
        def f(q), do: :my_dsl.filter(q, 99)
      end
      """

      {_meta, sites, _next} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @atom_lit)

      # Unregistered, `:my_dsl.filter` is an ordinary atom-module call, so its `99` argument is
      # ordinary runtime and the literal family mutates it — exactly what the `:skip` prevents.
      assert sites != []
      assert Enum.all?(sites, &(&1.mutator == :integer and &1.original_code == "99"))
    end
  end

  describe "a piped value reaches back to the macro's effective position-0 treatment" do
    # `x |> macro(...)` is `macro(x, ...)`, so the piped value is the macro's effective
    # argument 0 and must inherit position 0's treatment — even though it is the `|>` LHS,
    # analyzed away from the call's own args. Otherwise a pattern/opaque piped value is
    # mutated as runtime (a selector `case` spliced into pattern position) and poisons.

    test "match?: the piped LHS is a pattern (not mutated) while the visible expr arg is" do
      source = """
      defmodule PipedMatch do
        def f, do: 0 |> match?(1)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IntegerLiteral]
        )

      # `0 |> match?(1)` is `match?(0, 1)`: the piped `0` is match?'s **pattern** (effective
      # arg 0), the visible `1` is the matched expression. Every site is on the expression
      # `1`, none on the pattern `0` — and the metamutant must actually *compile* (a selector
      # spliced into the pattern would be "case not allowed in matches").
      assert sites != []
      assert Enum.all?(sites, &(&1.mutator == :integer and &1.original_code == "1"))
      assert_compiles(meta)
    end

    test "match?: a piped LHS that is the sole literal is left unmutated (pattern, not runtime)" do
      source = """
      defmodule PipedMatchOnly do
        def f(n), do: 0 |> match?(n)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IntegerLiteral]
        )

      # The visible arg `n` is a variable; the only literal is the piped `0`, which is the
      # pattern — so nothing is offered. Without the reach-back the `0` would be mutated in
      # pattern position and poison the single build.
      assert sites == []
      assert_compiles(meta)
    end

    @skip_piped """
    defmodule PipedSkip do
      import Mutare.Test.QueryDSL

      def run(y), do: (1 == y) |> where(:c)
    end
    """

    test "a `:skip` position-0 treatment leaves the piped value raw (the macro owns it)" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@skip_piped,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Mutare.Test.QueryDSL, :where, 2, :raw}]
        )

      # `where` registered with a uniform `:skip`: its effective arg 0 — the piped `1 == y` —
      # is left raw even though it sits in a *runtime* pipe position, so core mutates neither
      # the comparison nor the `1`. This is the "macro accepts arbitrary syntax" case.
      assert sites == []
      assert_compiles(meta)
    end

    test "without the registration, the same piped value mutates (the reach-back is doing the work)" do
      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@skip_piped,
          mutators: [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral]
        )

      # Unregistered, `where` is an ordinary piped call, so its LHS `1 == y` is ordinary
      # runtime and both the comparison and the `1` mutate.
      assert Enum.any?(sites, &(&1.mutator == :relational))
      assert Enum.any?(sites, &(&1.mutator == :integer))
    end

    # === a piped argument is NOT exempt from :skip/:hosted ===================
    #
    # The piped value (`x` in `x |> macro(...)`) is the macro's effective argument 0, so it
    # inherits position 0's treatment — a piped `:skip` argument is left **raw**, exactly as a
    # directly-written one is. This is deliberate and load-bearing: a `:skip` macro accepts a LHS
    # that is neither a valid expression nor a valid pattern, so treating it as ordinary runtime
    # would splice a selector `case` into opaque DSL and poison the single shared build.
    #
    # The reason this is *pinned down* is that the reason is easy to forget. The piped LHS looks
    # like an ordinary runtime expression the user wrote, which makes it tempting to "simplify" by
    # routing it straight to runtime and exempting it from `:skip`/`:hosted` — a change that reads
    # as a harmless cleanup but quietly reintroduces the poison. These tests are the guardrail:
    # they fail the moment a piped argument stops honouring its declared treatment, so that lapse
    # can't merge. (`:hosted` at the piped position is *undeliverable* — hosting needs the call's
    # own args — and is rejected outright rather than left raw; locked down in `hosted_test.exs`.)
    #
    # A nested-pipe LHS (`x |> a() |> macro(...)`, parsing as `(x |> a()) |> macro(...)`) is used
    # deliberately: a runtime exemption wouldn't just mutate the LHS, it would *descend* into the
    # inner stage too, so this is the strongest witness that `:skip` short-circuits the subtree.
    @piped_skip """
    defmodule PipedSkipArg do
      import Mutare.Test.QueryDSL

      def run(xs), do: xs |> Enum.sum() |> where(10)
    end
    """

    test "a piped `:skip` argument is left raw, never mutated as runtime (no exemption)" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@piped_skip,
          mutators: [Mutare.Mutators.Collection, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Mutare.Test.QueryDSL, :where, 2, :raw}]
        )

      # `where` registered `:skip`, so its effective arg 0 — the piped `xs |> Enum.sum()` — is
      # opaque. Nothing inside it is offered (not even the inner `Enum.sum/1` rename), and no
      # selector machinery is woven in: the pipe renders verbatim, with neither the mutated call
      # nor the `PipeEmit.hoist` closure (`mutare_piped`) a runtime exemption would have spliced.
      assert sites == []
      assert meta =~ "xs |> Enum.sum() |> where(10)"
      refute meta =~ "Enum.product"
      refute meta =~ "mutare_piped"
      assert_compiles(meta)
    end

    test "the same piped value mutates when its position is `:expression` (the `:skip` is what spares it)" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@piped_skip,
          mutators: [Mutare.Mutators.Collection, Mutare.Mutators.IntegerLiteral],
          call_routes: [{Mutare.Test.QueryDSL, :where, 2, [:expression, :raw]}]
        )

      # Same source, only effective arg 0 flipped to `:expression`: now the piped stage is reached
      # and `Enum.sum/1 -> Enum.product/1` fires, while the visible arg `10` (`:skip`) is still
      # spared. So the value *is* mutable — the previous test's silence is the `:skip` doing its
      # job, not some unrelated reason the piped value couldn't be mutated.
      triples = for s <- sites, do: {s.mutator, s.original_code, s.mutated_code}
      assert triples == [{:collection, "Enum.sum()", "Enum.product()"}]
      assert_compiles(meta)
    end

    test "a piped `:skip` argument spares only itself — the function tail still mutates" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@piped_skip,
          mutators: [Mutare.Mutators.Collection, Mutare.Mutators.ReturnValue],
          call_routes: [{Mutare.Test.QueryDSL, :where, 2, :raw}]
        )

      # ReturnValue fires on the body tail (outside the opaque arg); Collection does not fire
      # inside it. `:skip` spares the piped argument, not the whole function — it is not a blunt
      # "stop mutating here" switch.
      assert sites != []
      assert Enum.all?(sites, &(&1.mutator == :return_value))
      refute meta =~ "Enum.product"
      assert_compiles(meta)
    end
  end
end
