defmodule Mutare.MutatorsTest do
  use ExUnit.Case, async: true

  alias Mutare.Mutators
  alias Mutare.Mutator.Spec

  doctest Mutare.Mutators

  alias Mutare.Mutators.{
    AliasLiteral,
    Arithmetic,
    AtomLiteral,
    BitstringLiteral,
    CallRemoval,
    CharlistLiteral,
    Collection,
    CollectionArity,
    Conditional,
    ConventionAtom,
    DateTimeLiteral,
    DefaultDrop,
    FloatLiteral,
    GuardDrop,
    IfCondition,
    Integer,
    List,
    Literal,
    Logical,
    MapKeyword,
    MapLiteral,
    Math,
    ModeSwap,
    Numeric,
    OperandSwap,
    PatternSwap,
    PatternWildcard,
    Relational,
    RegexLiteral,
    RescueType,
    ReturnValue,
    StrictEquality,
    StringByte,
    StringCall,
    StringLiteral,
    StringSigilLiteral,
    TupleLiteral,
    WordListLiteral
  }

  describe "registry (single source of truth)" do
    test "all/0 is every registered module, in order — the default built-in set" do
      assert Mutators.all() == Keyword.values(Mutators.registry())

      assert Mutators.all() ==
               [Arithmetic, OperandSwap, Mutare.Mutators.Bitwise] ++
                 [Relational, StrictEquality, Logical, Literal, Conditional, IfCondition] ++
                 [List] ++
                 [Collection, CollectionArity, StringCall, StringByte, MapKeyword] ++
                 [Mutare.Mutators.KeywordDelete] ++
                 [Mutare.Mutators.MapSet, Mutare.Mutators.PeriodBoundary] ++
                 [CallRemoval, DefaultDrop] ++
                 [ModeSwap, Numeric, Math, Integer, ConventionAtom, StringLiteral, FloatLiteral] ++
                 [AtomLiteral] ++
                 [CharlistLiteral, WordListLiteral, StringSigilLiteral] ++
                 [MapLiteral, TupleLiteral, BitstringLiteral, Mutare.Mutators.BitstringSpec] ++
                 [RegexLiteral, DateTimeLiteral, AliasLiteral, ReturnValue, PatternSwap] ++
                 [PatternWildcard, RescueType, GuardDrop, Mutare.Mutators.GenServer]
    end

    test "families/0 are the registry's keys, in order — all on by default" do
      assert Mutators.families() == Keyword.keys(Mutators.registry())

      assert Mutators.families() ==
               [:arithmetic, :operand_swap, :bitwise] ++
                 [:relational, :strict_equality, :logical, :literal, :conditional] ++
                 [:if_condition, :list] ++
                 [:collection, :collection_arity, :string_call, :string_byte] ++
                 [:map_keyword, :keyword_delete, :map_set, :period_boundary] ++
                 [:call_removal] ++
                 [:default_drop, :mode_swap, :numeric, :math, :integer, :convention] ++
                 [:string, :float] ++
                 [:atom, :charlist, :word_list, :string_sigil, :map, :tuple, :bitstring] ++
                 [:bitstring_spec, :regex] ++
                 [
                   :datetime,
                   :alias,
                   :return_value,
                   :pattern_swap,
                   :pattern_wildcard,
                   :rescue_type,
                   :guard_drop,
                   :genserver
                 ]
    end

    test "resolve/1 maps family atoms to specs, preserving order" do
      assert Mutators.resolve([:relational, :arithmetic]) == [
               %Spec{module: Relational, name: :relational, opts: []},
               %Spec{module: Arithmetic, name: :arithmetic, opts: []}
             ]
    end

    test "resolve/1 accepts a custom module implementing the behaviour, mixed with families" do
      assert Mutators.resolve([:arithmetic, Mutare.Test.BooleanMutator]) |> Enum.map(& &1.module) ==
               [Arithmetic, Mutare.Test.BooleanMutator]
    end

    test "resolve/1 is idempotent: re-resolving its own output is a no-op" do
      specs = Mutators.resolve(Mutators.all())
      assert Enum.map(specs, & &1.module) == Mutators.all()
      assert Mutators.resolve(specs) == specs
    end

    test "resolve/1 maps any registered family by name" do
      assert Mutators.resolve([:conditional, :collection]) |> Enum.map(& &1.module) ==
               [Conditional, Collection]
    end

    test "resolve/1 carries {module, opts} configuration, stripping the :as name override" do
      assert Mutators.resolve([{Mutare.Test.BooleanMutator, threshold: 5}]) ==
               [%Spec{module: Mutare.Test.BooleanMutator, name: :boolean, opts: [threshold: 5]}]

      # `:as` renames the family (so the same module can run twice) and never
      # reaches the mutator's opts.
      assert Mutators.resolve([{Mutare.Test.BooleanMutator, as: :strict, threshold: 5}]) ==
               [%Spec{module: Mutare.Test.BooleanMutator, name: :strict, opts: [threshold: 5]}]
    end

    test "resolve/1 accepts a built-in family atom in a configured pair too" do
      assert Mutators.resolve([{:arithmetic, as: :arith2}]) ==
               [%Spec{module: Arithmetic, name: :arith2, opts: []}]
    end

    test "resolve/1 raises on an unknown family, listing the known ones" do
      message =
        assert_raise(ArgumentError, fn -> Mutators.resolve([:bogus_family]) end)
        |> Exception.message()

      assert message =~ "unknown mutator :bogus_family"
      assert message =~ "arithmetic"
      assert message =~ "relational"
    end

    test "resolve/1 raises on a module that does not implement the behaviour" do
      message =
        assert_raise(ArgumentError, fn -> Mutators.resolve([Enum]) end)
        |> Exception.message()

      assert message =~ "implementing Mutare.Mutator"
      assert message =~ "missing name/0"
    end

    test "implemented_by?/1 accepts a structural mutator that has no mutate/1" do
      # IfCondition is structural (condition_replacements/1) and no longer exports mutate/1.
      refute function_exported?(IfCondition, :mutate, 1)
      assert Mutare.Mutator.Dispatch.implemented_by?(IfCondition)
    end

    test "resolve/1 accepts a transform-managed family by module (no producing callback)" do
      # GuardDrop's logic lives in the transform — it exports only name/0, so implemented_by?/1
      # can't recognise it, but as a transform-managed family it still resolves by module.
      refute Mutare.Mutator.Dispatch.implemented_by?(GuardDrop)
      assert GuardDrop in Mutators.transform_managed()
      assert [%Spec{module: GuardDrop, name: :guard_drop}] = Mutators.resolve([GuardDrop])
    end

    test "every registered family is a Mutare.Mutator implementer or transform-managed" do
      # The category split: a registered family either implements the producing behaviour
      # (a "mutator") or is transform-managed (logic in `Mutare.Transform`, name/0 only). Nothing
      # else is legal — a registered module that is neither would fail to resolve by module.
      for module <- Mutators.all() do
        assert Mutare.Mutator.Dispatch.implemented_by?(module) or
                 module in Mutators.transform_managed(),
               "#{inspect(module)} is registered but neither implements Mutare.Mutator nor is " <>
                 "transform-managed"
      end
    end

    test "transform_managed/0 lists only registered families that don't implement the behaviour" do
      for module <- Mutators.transform_managed() do
        assert module in Mutators.all(),
               "#{inspect(module)} is transform-managed but not registered"

        refute Mutare.Mutator.Dispatch.implemented_by?(module),
               "#{inspect(module)} is listed transform-managed but implements Mutare.Mutator — " <>
                 "it should resolve via the producing-callback check instead"
      end
    end

    test "resolve/1 reports a non-atom entry rather than crashing on a guard" do
      assert_raise ArgumentError, ~r/unknown mutator "Arithmetic"/, fn ->
        Mutators.resolve(["Arithmetic"])
      end
    end

    test "every registered family's name/0 matches its registry atom" do
      # The registry atom is what `:mutators` config, reports, and `# mutare:ignore[...]` match;
      # the recorded family name is `module.name/0`. A drift between them would silently break a
      # `:mutators`/ignore reference, so pin them equal for every built-in.
      for {family, module} <- Mutators.registry() do
        assert module.name() == family,
               "#{inspect(module)}.name/0 returns #{inspect(module.name())}, " <>
                 "but it is registered as #{inspect(family)}"
      end
    end

    test "resolve/1 expands the :builtins token to the full default set, in order" do
      builtins = Mutators.resolve([:builtins])
      assert builtins == Mutators.resolve(Mutators.all())
      assert Enum.map(builtins, & &1.module) == Mutators.all()
    end

    test "resolve/1 rejects the removed :all group-token spelling" do
      assert_raise ArgumentError, ~r/unknown mutator :all/, fn ->
        Mutators.resolve([:all])
      end
    end

    test "resolve/1 extends the defaults when :builtins is included with custom mutators" do
      specs = Mutators.resolve([:builtins, Mutare.Test.BooleanMutator])
      assert Enum.map(specs, & &1.module) == Mutators.all() ++ [Mutare.Test.BooleanMutator]
    end

    test "resolve/1 replaces (does not extend) when :builtins is absent" do
      specs = Mutators.resolve([:arithmetic, Mutare.Test.BooleanMutator])
      assert Enum.map(specs, & &1.module) == [Arithmetic, Mutare.Test.BooleanMutator]
    end

    test "resolve/1 honours {:builtins, except: [...]}, dropping the named families" do
      specs = Mutators.resolve([{:builtins, except: [:arithmetic, :relational]}])
      names = Enum.map(specs, & &1.name)

      refute :arithmetic in names
      refute :relational in names
      # everything else survives, in order
      assert names == Mutators.families() -- [:arithmetic, :relational]
    end

    test "resolve/1 accepts a single atom (not a list) for :except" do
      names = Mutators.resolve([{:builtins, except: :arithmetic}]) |> Enum.map(& &1.name)
      assert names == Mutators.families() -- [:arithmetic]
    end

    test "resolve/1 reconfigures a built-in: exclude it, then re-add it configured" do
      specs =
        Mutators.resolve([
          {:builtins, except: [:convention]},
          {ConventionAtom, pairs: [[:active, :inactive]]}
        ])

      convention = Enum.filter(specs, &(&1.module == ConventionAtom))
      # exactly one convention instance, and it carries the custom config
      assert [%Spec{name: :convention, opts: [pairs: [[:active, :inactive]]]}] = convention
    end

    test "resolve/1 raises on an unknown family in :except, listing the known ones" do
      message =
        assert_raise(ArgumentError, fn ->
          Mutators.resolve([{:builtins, except: [:arithmitic]}])
        end)
        |> Exception.message()

      assert message =~ "unknown mutator family :arithmitic"
      assert message =~ ":except"
      assert message =~ "arithmetic"
    end

    test "resolve/1 raises on an unknown :builtins option (e.g. a misspelled :except)" do
      message =
        assert_raise(ArgumentError, fn ->
          Mutators.resolve([{:builtins, exclude: [:arithmetic]}])
        end)
        |> Exception.message()

      assert message =~ "unknown :builtins option"
      assert message =~ ":exclude"
      assert message =~ ":except"
    end

    test "resolve/1 raises on a non-keyword :builtins config" do
      assert_raise ArgumentError, ~r/:builtins options must be a keyword list/, fn ->
        Mutators.resolve([{:builtins, [:arithmetic]}])
      end
    end
  end
end
