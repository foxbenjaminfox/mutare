defmodule Mutare.TransformTest.PlusOneMutator do
  @moduledoc """
  A custom mutator that rewrites an integer literal `n` to `n + 1` — an *operator*
  expression. Legal in a body, but illegal in a pattern, so it exercises the
  head-pattern literal filter (only literal-valued replacements survive a head).
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :plus_one

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}) when is_integer(n),
    do: [{:+, [], [{:__block__, [], [n]}, {:__block__, [], [1]}]}]

  def mutate(_node), do: :skip
end

defmodule Mutare.TransformContextTest do
  # Context routing for value/key/module positions: atom-literal & alias context routing,
  # call-option-key opt-out, head-pattern literal lifting, module-level scaffold context, a
  # runtime defmodule's inline active-id read, and the coverage-helper xref warning. Split
  # from transform_test.exs.
  use ExUnit.Case, async: true

  alias Mutare.Site

  # The hoisted per-site active-id read makes a tupled-case subject read the bound
  # `mutare_active` variable, not the inline persistent_term read.
  defp selector_tuple, do: "case (case {mutare_active,"

  describe "custom structural & call-matching mutator extension points" do
    test "a custom return-position mutator participates via return_replacements/1" do
      {meta, triples} =
        redundancy_triples("def f(a, b), do: a + b", [Mutare.Test.ReturnMutator])

      # Discovered by exporting return_replacements/1 (not by hardcoding the module), and
      # offered at the clause tail like the built-in ReturnValue — under its own name.
      assert triples == [{:custom_return, "a + b", ":custom_return"}]
      assert_compiles(meta)
    end

    test "a custom condition mutator participates via condition_replacements/1" do
      {meta, triples} =
        redundancy_triples("def f(x), do: if(x, do: :a, else: :b)", [Mutare.Test.ConditionMutator])

      assert triples == [{:custom_condition, "x", "true"}]
      assert_compiles(meta)
    end

    test "a configurable custom return-position mutator receives opts" do
      {meta, triples} =
        redundancy_triples(
          "def f(a, b), do: a + b",
          [{Mutare.Test.ConfigurableReturnMutator, replacement: :configured_return}]
        )

      assert triples == [{:configurable_return, "a + b", ":configured_return"}]
      assert_compiles(meta)
    end

    test "a custom return mutator coexists with the built-in ReturnValue" do
      {_meta, triples} =
        redundancy_triples(
          "def f(a, b), do: a + b",
          [Mutare.Mutators.ReturnValue, Mutare.Test.ReturnMutator]
        )

      # Both return mutators fire at the same tail, each recorded under its own name.
      assert triples == [
               {:return_value, "a + b", "0"},
               {:return_value, "a + b", "1"},
               {:custom_return, "a + b", ":custom_return"}
             ]
    end

    test "a custom call mutator resolves aliased and imported forms via Transform.Calls" do
      aliased = """
      defmodule M do
        alias String, as: S
        def f(s), do: S.reverse(s)
      end
      """

      imported = """
      defmodule M do
        import String
        def f(s), do: reverse(s)
      end
      """

      # resolved_call_to/3 lets a third-party mutator match through alias and import — keying
      # on the real `String` module, never a hand-built key — and rebuild the swap in the
      # written form (the `S.` alias kept; the bare import kept bare).
      {ameta, asites, _} =
        Mutare.Transform.transform_string_with_sites(aliased,
          mutators: [Mutare.Test.AliasCallMutator]
        )

      assert [
               %Site{
                 mutator: :alias_call,
                 original_code: "S.reverse(s)",
                 mutated_code: "S.upcase(s)"
               }
             ] =
               asites

      assert_compiles(ameta)

      {imeta, isites, _} =
        Mutare.Transform.transform_string_with_sites(imported,
          mutators: [Mutare.Test.AliasCallMutator]
        )

      assert [%Site{mutator: :alias_call, original_code: "reverse(s)", mutated_code: "upcase(s)"}] =
               isites

      assert_compiles(imeta)
    end
  end

  describe "atom-literal context routing (data keys mutate; block keys/patterns do not)" do
    @atom [Mutare.Mutators.AtomLiteral]

    test "both values and data keyword/map keys mutate — and it renders" do
      source = """
      defmodule K do
        def f(x), do: %{status: :active, a: :b}
        def g(x), do: foo(x, timeout: :infinity)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @atom)

      # Syntax sugar no longer hides the key: both the keys (status/a/timeout) and the
      # values (active/b/infinity) mutate — 6 sites — exactly as the arrow form would.
      # A keyword *key* renders in keyword form (`status:`) so its diff stays legal; a
      # value renders as a bare atom (`:active`).
      assert length(sites) == 6
      assert Enum.all?(sites, &(&1.mutator == :atom))
      descriptions = Enum.map_join(sites, "\n", &Mutare.Site.describe/1)

      for key <- ~w(status a timeout) do
        assert descriptions =~ "#{key}: → mutare:"
      end

      for value <- ~w(active b infinity) do
        assert descriptions =~ ":#{value} → :mutare"
      end

      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a keyword-list key mutates and renders as a tuple (like [{:a, 1}])" do
      source = "defmodule KW do\n  def f, do: [a: 1, b: 2]\nend\n"

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @atom)

      # Both keys mutate; Sourceror renders the spliced selector in tuple form so the
      # keyword list stays legal (`[a: 1]` has no arrow form). The diff renders each
      # key in keyword form (`a:`) so a survivor reads as `[mutare: 1]`, not `[:mutare 1]`.
      assert Enum.map(sites, &Mutare.Site.describe/1) |> Enum.sort() ==
               ["atom  a: → mutare:", "atom  b: → mutare:"]

      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a struct's field keys are compile-constrained and never mutate (only values do)" do
      # `%S{name: …}` → `%S{mutare: …}` is a *compile* error (unknown struct field),
      # so the key must stay raw — both for the literal and the `%S{s | …}` update.
      source = """
      defmodule SF do
        def f, do: %S{name: :bob, role: :admin}
        def g(s), do: %S{s | role: :guest}
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @atom)

      # Only the field *values* mutate (:bob, :admin, :guest); no field-name key.
      assert Enum.map(sites, &Mutare.Site.describe/1) |> Enum.sort() ==
               ["atom  :admin → :mutare", "atom  :bob → :mutare", "atom  :guest → :mutare"]

      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a `for` comprehension's option keys are special-form and never mutate" do
      # `for ..., into: x` → `for ..., mutare: x` is `unsupported option :mutare given
      # to for` (a compile error), so the option keys stay raw.
      source = """
      defmodule FC do
        def f(l), do: for(x <- l, into: :acc, do: :hit)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @atom)

      # The option/body *values* :acc/:hit mutate; the :into/:do keys do not.
      assert Enum.map(sites, &Mutare.Site.describe/1) |> Enum.sort() ==
               ["atom  :acc → :mutare", "atom  :hit → :mutare"]

      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a `for` comprehension with do: before into: still compiles after transform" do
      # Sourceror can render this shape as a block after Mutare wraps the return
      # position in a selector. The metamutant must keep into: before the block body,
      # not emit it as a bare variable inside the do block.
      source = """
      defmodule ForDoBeforeInto do
        def f(types), do: for {key, :map} <- types, do: key, into: []
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.ReturnValue]
        )

      assert Enum.map(sites, & &1.mutator) == [:return_value, :return_value]
      assert_compiles(meta)
    end

    test "a `do:` block key is never mutated (it would otherwise fail to render)" do
      # Regression: a selector spliced into a `case`/`if` `do:` key is malformed
      # and crashed Sourceror's formatter outright (not even poison-recoverable).
      source = """
      defmodule B do
        def f(x) do
          case x do
            :foo -> :done
            _ -> :baz
          end
        end

        def g(x), do: if(x, do: :yes, else: :no)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @atom)

      # case bodies :done/:baz + if values :yes/:no mutate (4), plus the case-clause
      # pattern :foo (now mutated via tuple-the-scrutinee) = 5; the do:/else: keys do not.
      # (Non-convention sample atoms — :ok/:error are owned by ConventionAtom, not :atom.)
      assert length(sites) == 5
      assert Enum.any?(sites, &(&1.line == 4 and &1.mutator == :atom))
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "case/fn/receive clause patterns ARE mutated (with/for/else patterns are deferred); bodies are" do
      source = """
      defmodule P do
        def a(x) do
          case x do
            :foo -> :done
          end
        end

        def b, do: Enum.map([], fn :foo -> :a end)
        def c(l), do: for(:foo <- l, do: :hit)

        def d do
          with :foo <- run() do
            :done
          else
            :bad -> :err
          end
        end

        def e do
          receive do
            :msg -> :got
          end
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @atom)

      # Body atoms always mutate: a:[:done] b:[:a] c:[:hit] d:[:done,:err] e:[:got] = 6.
      # The `case`/`fn`/`receive` *clause patterns* now also mutate (`:foo`/`:foo`/`:msg`) = 3.
      # The `<-` generator/clause LHS (`for`, `with`) and the `with`/`try` `else` clause
      # pattern (`:bad`) are still deferred — so the total is 9, not 12. The `case` subject
      # is tupled (proof its clause pattern mutated via the tuple-the-scrutinee path).
      # (Non-convention sample atoms — :ok is owned by ConventionAtom, not :atom.)
      assert length(sites) == 9
      assert meta =~ selector_tuple()
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a struct's field map is not emptied, but its field values still mutate" do
      source = """
      defmodule S do
        def f, do: %User{name: :bob}
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.MapLiteral, Mutare.Mutators.AtomLiteral]
        )

      # No :map site (the struct's `%{}` wrapper is not offered); the field value
      # :bob still gets an :atom site.
      assert Enum.frequencies_by(sites, & &1.mutator) == %{atom: 1}
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a standalone map literal IS emptied" do
      source = "defmodule M do\n  def f, do: %{a: 1}\nend\n"

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.MapLiteral]
        )

      assert [%Site{mutator: :map}] = sites
    end

    test "a literal in a case-clause pattern IS mutated in place (tuple-the-scrutinee)" do
      # Once routed `:pattern` (never offered in place, since a selector `case` is illegal
      # in a pattern), the `1` is now mutated per-clause via the tuple-the-scrutinee rewrite
      # — like a head-pattern literal, but delivered in place rather than lifted.
      source = """
      defmodule L do
        def f(x) do
          case x do
            1 -> :a
            _ -> :b
          end
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IntegerLiteral]
        )

      # The `1` pattern (line 4) mutates; the diff stays focused on it (`:in_place`).
      assert Enum.any?(sites, &(&1.mutator == :integer and &1.kind == :in_place and &1.line == 4))
      assert meta =~ selector_tuple()
      assert {:ok, _} = Code.string_to_quoted(meta)
    end
  end

  describe "StringSigilLiteral (~s/~S routing)" do
    @sigil [Mutare.Mutators.StringSigilLiteral]

    test "a runtime ~s/~S sigil is mutated to \"\" and \"mutare\" (no-op variant dropped)" do
      {meta, triples} =
        redundancy_triples(
          """
          def f do
            a = ~s(hello)
            b = ~S(world)
            c = ~s()
            d = ~s(mutare)
            {a, b, c, d}
          end
          """,
          @sigil
        )

      assert {:string_sigil, "~s(hello)", ~s("")} in triples
      assert {:string_sigil, "~s(hello)", ~s("mutare")} in triples
      assert {:string_sigil, "~S(world)", ~s("")} in triples
      assert {:string_sigil, "~S(world)", ~s("mutare")} in triples
      # ~s() ≡ "" so only the sentinel; ~s(mutare) so only the empty string.
      assert {:string_sigil, "~s()", ~s("mutare")} in triples
      refute Enum.any?(triples, &match?({:string_sigil, "~s()", ~s("")}, &1))
      assert {:string_sigil, "~s(mutare)", ~s("")} in triples
      refute Enum.any?(triples, &match?({:string_sigil, "~s(mutare)", ~s("mutare")}, &1))
      assert_compiles(meta)
    end

    test "an interpolated ~s is mutated as a whole; a sigil in a pattern position is not" do
      {meta, triples} =
        redundancy_triples(
          """
          def f(s), do: ~s(a\#{s}b)
          def g(~S(hello)), do: :ok
          def g(_), do: :no
          """,
          @sigil
        )

      # The interpolated `~s` mutates as a whole — its runtime value is never statically
      # "" or "mutare", so both variants apply (the inner `\#{s}` keeps interpolating in
      # the baseline branch). A `~S(...)` in a pattern is never offered (a selector `case`
      # is illegal in a match).
      assert {:string_sigil, "~s(a\#{s}b)", ~s("")} in triples
      assert {:string_sigil, "~s(a\#{s}b)", ~s("mutare")} in triples
      refute Enum.any?(triples, fn {_m, o, _mut} -> o == "~S(hello)" end)
      assert_compiles(meta)
    end
  end

  describe "call-option keys: mutator-owned policy (keyword list as a call's final arg)" do
    # Bare AtomLiteral mutates call-option keys; configured with `call_option_keys: false`
    # it skips them. `IntegerLiteral` rides along so an option *value* still mutates either way.
    @kw [Mutare.Mutators.AtomLiteral, Mutare.Mutators.IntegerLiteral]
    @kw_off [
      {Mutare.Mutators.AtomLiteral, call_option_keys: false},
      Mutare.Mutators.IntegerLiteral
    ]

    defp atom_keys(source, opts) do
      {meta, sites, _} = Mutare.Transform.transform_string_with_sites(source, opts)

      keys =
        sites
        |> Enum.filter(&(&1.mutator == :atom))
        |> Enum.map(&Mutare.Site.describe/1)
        |> Enum.sort()

      {keys, meta}
    end

    test "default: a call's trailing keyword keys mutate" do
      source = "defmodule C do\n  def f(x), do: foo(x, timeout: 5, retries: 3)\nend\n"
      {keys, meta} = atom_keys(source, mutators: @kw)

      assert keys == ["atom  retries: → mutare:", "atom  timeout: → mutare:"]
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "`call_option_keys: false`: the keys are left raw, but their values still mutate" do
      source = "defmodule C do\n  def f(x), do: foo(x, timeout: 5, retries: 3)\nend\n"
      {keys, meta} = atom_keys(source, mutators: @kw_off)

      assert keys == []
      # values still mutate, so the call isn't left untouched
      {_m, sites, _} = Mutare.Transform.transform_string_with_sites(source, mutators: @kw_off)
      assert Enum.any?(sites, &(&1.mutator == :integer))
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "`call_option_keys: false` gates a piped call's trailing keyword key too" do
      source = "defmodule P do\n  def f(x), do: x |> foo(timeout: 5)\nend\n"
      assert {[], _} = atom_keys(source, mutators: @kw_off)
      assert {["atom  timeout: → mutare:"], _} = atom_keys(source, mutators: @kw)
    end

    test "`call_option_keys: false` does NOT affect standalone map/keyword-list literal keys" do
      # These aren't call arguments, so the opt leaves them mutating.
      map = "defmodule M do\n  def f, do: %{timeout: 5}\nend\n"
      kwl = "defmodule K do\n  def f, do: [timeout: 5]\nend\n"

      assert {["atom  timeout: → mutare:"], _} = atom_keys(map, mutators: @kw_off)
      assert {["atom  timeout: → mutare:"], _} = atom_keys(kwl, mutators: @kw_off)
    end

    test "a tuple ending in a keyword list is not mistaken for call options" do
      # `{a, [b: 1]}` is a data tuple, not a call — its `:b` key mutates regardless.
      source = "defmodule T do\n  def f(a), do: {a, [b: 1]}\nend\n"
      assert {["atom  b: → mutare:"], _} = atom_keys(source, mutators: @kw_off)
    end

    test "the opt is per-mutator: a different mutator's keys are unaffected" do
      # Integer keys are IntegerLiteral's; configuring AtomLiteral off leaves them mutating.
      source = "defmodule N do\n  def f(x), do: foo(x, [{1, :a}])\nend\n"

      {_m, sites, _} = Mutare.Transform.transform_string_with_sites(source, mutators: @kw_off)
      assert Enum.any?(sites, &(&1.mutator == :integer and &1.line == 2))
    end

    test "core does not interpret `call_option_keys` for a mutator without the callback" do
      # This pair-list shape is tagged as a trailing call-options candidate, but IntegerLiteral
      # does not declare the policy callback. Its similarly named opt is therefore inert.
      source = "defmodule N do\n  def f(x), do: foo(x, [{1, :a}])\nend\n"

      {_m, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [{Mutare.Mutators.IntegerLiteral, call_option_keys: false}]
        )

      assert Enum.any?(sites, &(&1.mutator == :integer and &1.original_code == "1"))
    end

    test "ConventionAtom can own the same positional policy" do
      source = "defmodule C do\n  def f, do: foo(ok: 1)\nend\n"

      {_m, default_sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.ConventionAtom]
        )

      {_m, gated_sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [{Mutare.Mutators.ConventionAtom, call_option_keys: false}]
        )

      assert Enum.any?(default_sites, &(&1.mutator == :convention))
      refute Enum.any?(gated_sites, &(&1.mutator == :convention))
    end

    test "gated keys leave no id gap — ids stay contiguous" do
      source = "defmodule C do\n  def f(x), do: foo(x, timeout: 5, retries: 3)\nend\n"

      {_m, sites, next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @kw_off)

      ids = sites |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.to_list(1..(next_id - 1))
    end
  end

  describe "alias context routing (value vs. module/name position)" do
    @alias [Mutare.Mutators.AliasLiteral]

    test "an alias used as a value mutates; the call-module position does not" do
      source = """
      defmodule D do
        def run, do: apply(Greeter, :hello, [])
        def direct, do: Greeter.hello()
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @alias)

      # apply(Greeter, …) → Greeter is a value (1 site); Greeter.hello() is a
      # call-module position (opaque form) and is not offered.
      assert [%Site{mutator: :alias, line: 2}] = sites
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "struct names and directives are not mutated; value args are" do
      source = """
      defmodule D do
        alias Foo.Bar
        def f(x), do: %Bar{a: x}
        def g(x), do: struct(Bar, a: x)
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @alias)

      # The `alias` directive and the `%Bar{}` struct name are excluded; only the
      # `struct(Bar, …)` value argument mutates.
      assert [%Site{mutator: :alias, line: 4}] = sites
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "defimpl/defprotocol/defdelegate module references are not mutated (poison-clean)" do
      source = """
      defmodule D do
        defdelegate foo(x), to: Helper
      end

      defprotocol P do
        def encode(x)
      end

      defimpl P, for: Foo do
        def encode(x), do: apply(Helper, :run, [x])
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @alias)

      # The defdelegate `to:`, the protocol name, and the `for:` type are excluded;
      # the defimpl *body* still mutates its value alias `Helper`.
      assert [%Site{mutator: :alias}] = sites
      assert meta =~ "defimpl P, for: Foo"
      assert {:ok, _} = Code.string_to_quoted(meta)
    end
  end

  describe "head-pattern literal lifting" do
    @literal [Mutare.Mutators.IntegerLiteral]

    test "a literal in a def head is mutated by lifting (not in place)" do
      # A `case` selector is illegal in a pattern, so a head literal can only be
      # mutated by duplicating the clause group — like a guard. A single-clause
      # function with no guard now lifts solely to carry the head mutant.
      source = "defmodule H do\n  def f(1), do: :ok\nend\n"

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @literal)

      assert [
               %Site{mutator: :integer, kind: :lifted, original_code: "1", mutated_code: "2"},
               %Site{mutator: :integer, kind: :lifted, original_code: "1", mutated_code: "0"}
             ] =
               Enum.sort_by(sites, & &1.id)

      assert meta =~ "def f(mutare_arg1) do"
      assert [{H, _}] = Mutare.Test.Compile.string(meta)
    end

    test "both the key and the value of a map pattern mutate (%{1 => 2})" do
      source = "defmodule H do\n  def f(%{1 => 2}), do: :ok\nend\n"

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @literal)

      # the `1` key → {2, 0}; the `2` value → {3, 1, 0}; both lifted, none in place.
      assert Enum.all?(sites, &(&1.kind == :lifted and &1.mutator == :integer))

      assert MapSet.new(sites, &{&1.original_code, &1.mutated_code}) ==
               MapSet.new([{"1", "2"}, {"1", "0"}, {"2", "3"}, {"2", "1"}, {"2", "0"}])

      assert [{H, _}] = Mutare.Test.Compile.string(meta)
    end

    test "a key mutation that would duplicate a sibling key is dropped (not poisoned)" do
      # `%{1 => a, 0 => b}`: `1 → 0` and `0 → 1` would each make a duplicate map key
      # (a compile error). We detect the collision and drop just those mutations,
      # rather than emitting them and relying on poison recovery — the rest survive.
      source = "defmodule H do\n  def f(%{1 => a, 0 => b}), do: {a, b}\nend\n"

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @literal)

      pairs = MapSet.new(sites, &{&1.original_code, &1.mutated_code})
      # the non-colliding mutations remain...
      assert MapSet.member?(pairs, {"1", "2"})
      assert MapSet.member?(pairs, {"0", "-1"})
      # ...and the colliding ones (1 → 0, 0 → 1) are gone.
      refute MapSet.member?(pairs, {"1", "0"})
      refute MapSet.member?(pairs, {"0", "1"})

      # The proof it mattered: the metamutant compiles (a duplicate key would not).
      assert [{H, _}] = Mutare.Test.Compile.string(meta)
    end

    test "a bitstring type specifier in a head is not mutated (it could be illegal)" do
      # The value side mutates, but the spec side (`size(8)`) is skipped: a `unit(0)`
      # / `size`-literal swap risks an illegal specifier that would poison the build.
      source = "defmodule H do\n  def f(<<8::size(8)>>), do: :ok\nend\n"

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @literal)

      # Only the value `8` (left of `::`) mutates; the spec `size(8)` is untouched.
      assert [
               %Site{kind: :lifted, original_code: "8", mutated_code: "9"},
               %Site{kind: :lifted, original_code: "8", mutated_code: "7"},
               %Site{kind: :lifted, original_code: "8", mutated_code: "0"}
             ] =
               Enum.sort_by(sites, & &1.id)
    end

    test "a keyword/map key in a head is a label and is not mutated" do
      source = "defmodule H do\n  def f(%{a: 1}), do: :ok\nend\n"

      {_meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @literal)

      # The `:a` key is skipped; only the `1` value lifts.
      assert MapSet.new(sites, & &1.mutated_code) == MapSet.new(["2", "0"])
    end

    test "head literals and guard operators lift together, sharing the dispatcher" do
      source = """
      defmodule H do
        def f(0, x) when x > 0, do: :a
        def f(_, _), do: :b
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.IntegerLiteral, Mutare.Mutators.Relational]
        )

      lifted = Enum.filter(sites, &(&1.kind == :lifted and &1.operation == :replace))
      # guard `>` → {>=, <} (relational); head `0` → {1, -1} (literal). Both lifted.
      assert Enum.any?(lifted, &(&1.mutator == :relational and &1.original_form == :>))
      assert Enum.any?(lifted, &(&1.mutator == :integer and &1.original_code == "0"))

      assert meta =~ ~r/def f\(mutare_arg1, mutare_arg2\) do/
      assert [{H, _}] = Mutare.Test.Compile.string(meta)
    end

    test "a default-arg function lifts: head literal mutates, default value rides the dispatcher" do
      # Default args expand to multiple arities; the function is lifted with the
      # `\\` defaults kept on the public dispatcher (preserving the arity contract)
      # while the lifted base takes the full arity. So the head literal `1` now
      # lifts (it never did while default-arg functions were left in place), and the
      # default value `2` still mutates in place — on the dispatcher.
      source = "defmodule H do\n  def f(1, b \\\\ 2), do: b\nend\n"

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source, mutators: @literal)

      assert meta =~ "__mutare_f_2_g1"
      # The head literal `1` lifts; the default `2` mutates in place.
      assert MapSet.new(sites, &{&1.original_code, &1.kind}) ==
               MapSet.new([{"1", :lifted}, {"2", :in_place}])

      # The dispatcher's second arg keeps the `\\` default (so `f/1` still resolves)...
      assert meta =~ ~r/mutare_arg2 \\\\/
      # ...and the lifted base function takes the full arity with `\\` stripped.
      assert meta =~ ~r/defp __mutare_f_2_g1\(mutare_active, 1, b\)/
      refute meta =~ ~r/defp __mutare_f_2_g1\([^)]*\\\\/
      assert [{H, _}] = Mutare.Test.Compile.string(meta)
    end

    test "a mutator that would emit a pattern-illegal node is filtered out of heads" do
      # The compile-safety net: only literal-valued mutations survive in a pattern.
      # This mutator rewrites an integer to `n + 1` (an operator — illegal in a
      # pattern), so it must produce no *head* site (and the metamutant compiles),
      # while still mutating the same literal in a body position.
      source = "defmodule H do\n  def f(1), do: 9\nend\n"

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.TransformTest.PlusOneMutator]
        )

      # No lifted head site — the `1` head mutant was filtered (would not compile).
      refute Enum.any?(sites, &(&1.kind == :lifted))
      # The body `9` still mutates in place.
      assert [%Site{kind: :in_place, original_code: "9"}] = sites
      assert [{H, _}] = Mutare.Test.Compile.string(meta)
    end
  end

  test "the default set fires the expanded families (logical, integer, boolean, conditional, …)" do
    source = """
    defmodule D do
      def f(a, b), do: a and b + 1
      def flag, do: true
    end
    """

    {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)
    by = Enum.frequencies_by(sites, & &1.mutator)

    # b + 1 → b - 1
    assert by[:arithmetic] == 1
    # a and _ → a or _
    assert by[:logical] == 1
    # (a and _) → true / false
    assert by[:conditional] == 2
    # 1 → {2, 0}
    assert by[:integer] == 2
    # true → false
    assert by[:boolean] == 1
    assert {:ok, _} = Code.string_to_quoted(meta)
  end

  describe "coverage helper xref warning" do
    # The selector catch-alls call `:mutare_cov.hit/1`, a helper that in an umbrella
    # lives in a generated sibling app the mutated app declares no dep on — so it
    # may be compiled later and draw a benign "undefined function" xref warning.
    # `Transform` prepends `@compile {:no_warn_undefined, …}` to every module body
    # to silence it; the call still resolves at runtime. (Suppression itself can
    # only be observed where the helper is absent — Mutare's own VM ships a
    # `:mutare_cov` test stand-in — so the end-to-end check lives in
    # `Mutare.UmbrellaTest`; here we pin that the attribute is emitted, per module.)
    @attr "@compile {:no_warn_undefined, {#{inspect(Mutare.Coverage.Recorder.fixture_module())}, :hit, 1}}"

    @multi_module """
    defmodule Outer do
      defmodule Inner do
        def add(a, b), do: a + b
      end

      def sub(a, b), do: a - b
    end

    defimpl String.Chars, for: Outer do
      def to_string(_), do: "a" <> "b"
    end
    """

    test "every module (incl. nested and defimpl) carries the no-warn attribute" do
      {meta, _sites, _next_id} = Mutare.Transform.transform_string_with_sites(@multi_module)

      # One per module body: Outer, Inner, and the String.Chars impl.
      occurrences = meta |> String.split(@attr) |> length() |> Kernel.-(1)
      assert occurrences == 3
      assert {:ok, _ast} = Code.string_to_quoted(meta)
    end

    test "the attribute targets exactly the MFA the catch-all calls (no drift)" do
      # If the helper module/arity ever drifts from what `record_ast/1` emits, the
      # attribute would stop matching the call and the warning would silently
      # return — so assert both reference the same `<helper>.hit(...)`.
      helper = inspect(Mutare.Coverage.Recorder.fixture_module())

      {meta, _sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule M do\n  def f(a, b), do: a + b\nend\n"
        )

      assert meta =~ "#{helper}.hit("
      assert meta =~ @attr
    end
  end

  describe "module-level compile-time statements route through scaffold context" do
    # A module body runs *once*, at compile time, with mutant 0 active — so a selector
    # spliced into a module-level statement (the `if` condition, the `for` generator,
    # an unquoted generated head pattern, or a bare compile-time calculation) could
    # never activate at runtime. Those are left inert; explicit `def` *bodies*
    # reached from the scaffold still mutate. Lifting stays off for such functions
    # (no guard/clause-drop/head-pattern mutants).

    test "an if with no definitions is inert, while ordinary function bodies still mutate" do
      source = """
      defmodule CompileOnlyIf do
        if true do
          Module.put_attribute(__MODULE__, :compile_only, 1 + 2)
        end

        def run(x), do: x + 3
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.IntegerLiteral]
        )

      assert meta =~ "if true do"
      refute Enum.any?(sites, &(&1.original_code in ["true", "1 + 2"]))
      assert Enum.any?(sites, &(&1.original_code == "x + 3"))
      assert_compiles(meta)
    end

    test "a for with no definitions is inert, while ordinary function bodies still mutate" do
      source = """
      defmodule CompileOnlyFor do
        for n <- [1, 2] do
          Module.put_attribute(__MODULE__, :seen, n + 1)
        end

        def run(x), do: x + 10
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.List]
        )

      assert meta =~ "for n <- [1, 2] do"
      refute Enum.any?(sites, &(&1.original_code in ["[1, 2]", "n + 1"]))
      assert Enum.any?(sites, &(&1.original_code == "x + 10"))
      assert_compiles(meta)
    end

    test "a parenthesized statement block with no definitions is inert" do
      source = """
      defmodule CompileOnlyBlock do
        (1 + 2; 3 + 4)

        def run(x), do: x + 5
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic]
        )

      assert meta =~ "1 + 2"
      assert meta =~ "3 + 4"
      refute Enum.any?(sites, &(&1.original_code in ["1 + 2", "3 + 4"]))
      assert Enum.any?(sites, &(&1.original_code == "x + 5"))
      assert_compiles(meta)
    end

    test "an unknown module-level macro block keeps its generated runtime body mutatable" do
      source = """
      defmodule RuntimeDSL do
        defmacro runtime_fun(name, do: body) do
          quote do
            def unquote(name)(), do: unquote(body)
          end
        end
      end

      defmodule UsesRuntimeDSL do
        import RuntimeDSL

        runtime_fun :value do
          1 + 2
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.AtomLiteral]
        )

      refute Enum.any?(sites, &(&1.original_code == ":value"))
      assert Enum.any?(sites, &(&1.mutator == :arithmetic and &1.original_code == "1 + 2"))
      assert_compiles(meta)
    end

    test "a conditionally-defined function: the `if` condition is inert, the body mutates" do
      source = """
      defmodule Cond do
        @enabled true

        if @enabled do
          def discount(price), do: price * 2
        end
      end
      """

      {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      # Nothing mutates the `if @enabled` condition; it renders verbatim.
      assert meta =~ "if @enabled do"
      refute Enum.any?(sites, &(&1.original_code == "@enabled"))
      # The body still mutates (`price * 2` → arithmetic, the `2` literal, a return).
      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      assert_compiles(meta)
    end

    test "a comprehension of heads: the generator is inert, every body mutates" do
      source = """
      defmodule Heads do
        for tier <- [:gold, :silver, :bronze] do
          def perks(unquote(tier)), do: length([1, 2, 3])
        end
      end
      """

      {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      # The generator literal survives verbatim — not rewritten into a selector — so
      # no atom/list mutant is offered on it (those would be compile-time-inert).
      assert meta =~ "for tier <- [:gold, :silver, :bronze] do"

      refute Enum.any?(
               sites,
               &(&1.original_code in (~w(:gold :silver :bronze) ++
                                        ["[:gold, :silver, :bronze]"]))
             )

      # The constant body `length([1, 2, 3])` still mutates (the inner list → `[]`).
      assert Enum.any?(sites, &(&1.mutator == :list))
      assert_compiles(meta)
    end

    test "mixed: a normal head and metaprogrammed heads of one function both mutate, independently" do
      source = """
      defmodule Mixed do
        def code(0), do: 53

        for n <- 1..3 do
          def code(unquote(n)), do: unquote(n) * 10
        end
      end
      """

      {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      # The `1..3` generator is compile-time: its endpoints are not mutated.
      assert meta =~ "for n <- 1..3 do"
      refute Enum.any?(sites, &(&1.original_code in ~w(1 3)))

      # `code/1` is not lifted (its clause set is augmented by the comprehension), so
      # both the top-level head body (`53`) and the metaprogrammed head body
      # (`unquote(n) * 10`) mutate in place.
      assert Enum.all?(sites, &(&1.kind == :in_place))
      assert Enum.any?(sites, &(&1.original_code == "53"))
      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      assert_compiles(meta)
    end

    test "several scaffolds nested (for inside if): the body is still reached, the scaffold inert" do
      source = """
      defmodule Nested do
        @enabled true

        if @enabled do
          for n <- [1, 2] do
            def double(unquote(n)), do: unquote(n) + unquote(n)
          end
        end
      end
      """

      {meta, sites, _next_id} = Mutare.Transform.transform_string_with_sites(source)

      assert meta =~ "if @enabled do"
      assert meta =~ "for n <- [1, 2] do"
      # The body `unquote(n) + unquote(n)` mutates through two layers of scaffold...
      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      # ...while the `[1, 2]` generator stays inert.
      refute Enum.any?(sites, &(&1.original_code == "[1, 2]"))
      assert_compiles(meta)
    end

    test "a scaffold whose definition is scoped in defimpl still leaves the generator inert" do
      source = """
      defprotocol Enc do
        def enc(x)
      end

      defmodule ScopedImpls do
        for type <- [Foo] do
          defimpl Enc, for: type do
            def enc(x), do: x + 1
          end
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.List]
        )

      assert meta =~ "for type <- [Foo] do"
      refute Enum.any?(sites, &(&1.original_code == "[Foo]"))
      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      assert_compiles(meta)
    end

    test "a scaffold whose definition is scoped in defmodule still leaves the condition inert" do
      source = """
      defmodule ScopedModules do
        if true do
          defmodule Inner do
            def value, do: 1 + 2
          end
        end
      end
      """

      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Arithmetic, Mutare.Mutators.IntegerLiteral]
        )

      assert meta =~ "if true do"
      refute Enum.any?(sites, &(&1.original_code == "true"))
      assert Enum.any?(sites, &(&1.mutator == :arithmetic))
      assert_compiles(meta)
    end
  end

  describe "a runtime defmodule in a function body uses the inline active-id read" do
    # A `defmodule` *evaluated at runtime* (inside a function body, not a module-level
    # scaffold) defines a new module whose `def` bodies are a fresh scope — they cannot see
    # the enclosing function's hoisted `active_var` binding. A selector emitted there must
    # therefore use the self-contained `:persistent_term` read; the hoisted bare-variable
    # form would raise `undefined variable "mutare_active"` when the outer function runs and
    # compiles the inner module (and the outer prologue, with nothing in its own scope to
    # read it, would be a dead binding). `Code.compile_string` of the outer module alone
    # cannot catch this — the inner `defmodule` is only compiled when `build/0` *runs*.
    @runtime_defmodule """
    defmodule RuntimeDefmoduleOuter do
      def build do
        defmodule RuntimeDefmoduleInner do
          def f, do: 1 + 2
        end
      end
    end
    """

    test "the nested module's selector is self-contained and the outer has no prologue" do
      {meta, sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@runtime_defmodule,
          mutators: [Mutare.Mutators.Arithmetic]
        )

      assert length(sites) == 1
      # The inner selector reads `:persistent_term` directly, not the hoisted bare variable.
      assert meta =~ "case :persistent_term.get(#{inspect(Mutare.Selector.key())}, 0) do"
      refute meta =~ "case mutare_active do"
      # Every mutation lives in the nested module, so `build/0` gets no (dead) prologue.
      refute meta =~ "mutare_active = :persistent_term.get"
    end

    test "the metamutant runs: invoking build/0 compiles the inner module without error" do
      {meta, _sites, _next_id} =
        Mutare.Transform.transform_string_with_sites(@runtime_defmodule,
          mutators: [Mutare.Mutators.Arithmetic]
        )

      # Resolve the generated modules as runtime atoms — they don't exist at this test's
      # compile time (the inner one only at `build/0` runtime), so a literal alias would
      # draw an "undefined module" warning.
      outer = :"Elixir.RuntimeDefmoduleOuter"
      inner = :"Elixir.RuntimeDefmoduleOuter.RuntimeDefmoduleInner"

      # Invoking `build/0` compiles the nested `defmodule` — the moment the bug surfaced.
      # On the buggy (bare-variable) form this raises a `CompileError`. Read-only on
      # `:persistent_term` (this suite is `async: true`), so assert against the only two
      # values the mutation can yield rather than forcing a baseline.
      # `with_diagnostics` swallows the compile's warnings per-process (async-safe,
      # unlike capturing the shared :stderr device).
      Code.with_diagnostics(fn ->
        Code.compile_string(meta)
        apply(outer, :build, [])
      end)

      assert apply(inner, :f, []) in [3, -1]
    end
  end

  # The same, parameterised by the mutator set — for the equivalent-sibling suppression
  # tests, which exercise Logical/List/Conditional combinations.
  defp redundancy_triples(body, mutators) do
    source = "defmodule M do\n  #{String.trim_trailing(body)}\nend\n"

    {meta, sites, _next_id} =
      Mutare.Transform.transform_string_with_sites(source, mutators: mutators)

    triples = for s <- sites, do: {s.mutator, s.original_code, s.mutated_code}
    {meta, triples}
  end

  defp assert_compiles(meta) do
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end
end
