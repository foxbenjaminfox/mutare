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
    BooleanLiteral,
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
    IntegerCall,
    IntegerLiteral,
    List,
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
    TemporalOrder,
    TupleLiteral,
    WordListLiteral
  }

  describe "registry (single source of truth)" do
    test "all/0 is every registered module, in order — the default built-in set" do
      assert Mutators.all() == Keyword.values(Mutators.registry())

      assert Mutators.all() ==
               [Arithmetic, OperandSwap, Mutare.Mutators.Bitwise] ++
                 [Relational, StrictEquality, Logical, IntegerLiteral, BooleanLiteral] ++
                 [Conditional, IfCondition] ++
                 [List] ++
                 [Collection, CollectionArity, StringCall, StringByte, MapKeyword] ++
                 [Mutare.Mutators.KeywordDelete] ++
                 [Mutare.Mutators.MapSet, Mutare.Mutators.PeriodBoundary, TemporalOrder] ++
                 [CallRemoval, DefaultDrop] ++
                 [
                   ModeSwap,
                   Numeric,
                   Math,
                   IntegerCall,
                   ConventionAtom,
                   StringLiteral,
                   FloatLiteral
                 ] ++
                 [AtomLiteral] ++
                 [CharlistLiteral, WordListLiteral, StringSigilLiteral] ++
                 [MapLiteral, TupleLiteral, BitstringLiteral, Mutare.Mutators.BitstringSpec] ++
                 [RegexLiteral, DateTimeLiteral, AliasLiteral, ReturnValue, PatternSwap] ++
                 [PatternWildcard, RescueType, GuardDrop, Mutare.Mutators.ClauseDrop] ++
                 [Mutare.Mutators.GenServer]
    end

    test "families/0 are the registry's keys, in order — all on by default" do
      assert Mutators.families() == Keyword.keys(Mutators.registry())

      assert Mutators.families() ==
               [:arithmetic, :operand_swap, :bitwise] ++
                 [:relational, :strict_equality, :logical, :integer, :boolean, :conditional] ++
                 [:if_condition, :list] ++
                 [:collection, :collection_arity, :string_call, :string_byte] ++
                 [:map_keyword, :keyword_delete, :map_set, :period_boundary, :temporal_order] ++
                 [:call_removal] ++
                 [:default_drop, :mode_swap, :numeric, :math, :integer_call, :convention] ++
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
                   :clause_drop,
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
      assert Mutators.resolve([:arithmetic, Mutare.Test.AndOrMutator]) |> Enum.map(& &1.module) ==
               [Arithmetic, Mutare.Test.AndOrMutator]
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
      # No init/1 on the module, so the normalized config is the opts themselves.
      assert Mutators.resolve([{Mutare.Test.AndOrMutator, threshold: 5}]) ==
               [
                 %Spec{
                   module: Mutare.Test.AndOrMutator,
                   name: :and_or,
                   opts: [threshold: 5],
                   config: [threshold: 5]
                 }
               ]

      # `:as` renames the family (so the same module can run twice) and never
      # reaches the mutator's opts.
      assert Mutators.resolve([{Mutare.Test.AndOrMutator, as: :strict, threshold: 5}]) ==
               [
                 %Spec{
                   module: Mutare.Test.AndOrMutator,
                   name: :strict,
                   opts: [threshold: 5],
                   config: [threshold: 5]
                 }
               ]
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
      specs = Mutators.resolve([:builtins, Mutare.Test.AndOrMutator])
      assert Enum.map(specs, & &1.module) == Mutators.all() ++ [Mutare.Test.AndOrMutator]
    end

    test "resolve/1 replaces (does not extend) when :builtins is absent" do
      specs = Mutators.resolve([:arithmetic, Mutare.Test.AndOrMutator])
      assert Enum.map(specs, & &1.module) == [Arithmetic, Mutare.Test.AndOrMutator]
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

      # The one `except:` parser (`Mutare.Mutator.Families.except!/4`) — the same message shape a
      # plugin's `families: {:all, except: […]}` gets.
      assert message =~ "unknown built-in families in :except: [:arithmitic]"
      assert message =~ "valid families are"
      assert message =~ ":arithmetic"
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

  describe "family ownership splits (no two families emit the same mutant)" do
    # The splits are documented per owning family (OperandSwap excludes the ordering operators
    # Relational reflects; StrictEquality relaxes while Relational flips polarity; Arithmetic owns
    # `div`/`rem` and Numeric the other bare-Kernel pairs; `true`/`false`/`nil` belong to
    # Literal/Conditional, not AtomLiteral) but nothing structural enforces them: two families
    # emitting an identical mutant at one position would simply both appear. This exercises every
    # documented contact point under the *whole* default set and pins that no position's rendered
    # mutant is claimed by more than one family. (The transform surfaces such duplicates — a
    # mutator that re-emits Relational's `a < b` for `a > b` shows up twice here — so this can fail.)
    @contact_points """
    defmodule Splits do
      def ordering(a, b), do: {a > b, a >= b, a < b, a <= b}
      def equality(a, b), do: {a == b, a != b, a === b, a !== b}
      def membership(x, xs), do: {x in xs, x not in [1, 2]}
      def arithmetic(a, b), do: {a + b, a - b, a * b, a / b, a ** b, -a, div(a, b), rem(a, b)}
      def numeric(a, b, x), do: {min(a, b), max(a, b), round(x), trunc(x), ceil(x), floor(x)}
      def qualified(a, b, x), do: {Kernel.min(a, b), Kernel.div(a, b), Float.ceil(x), Float.floor(x)}
      def piped(a, b), do: {a |> Kernel.-(b), a |> div(b), a |> min(b), a |> Kernel.<(b)}
      def sequences(a, b), do: {a <> b, a ++ b, a -- b}
      def boolean(p, q), do: {p and q, p or q, p && q, p || q, not p, !p}
      def literals, do: {true, false, nil, :ok, :error, :pending, 0, 1, 2, -1, 1.0, "", "s", [], [1], %{}, {}}
      def branches(p, x) do
        if p, do: x, else: nil
      end
    end
    """

    test "every rendered mutant at a position belongs to exactly one family" do
      %{sites: sites} =
        Mutare.Transform.transform_string_with_sites(@contact_points, warnings: false)

      # Sanity: the fixture actually exercised the families the splits are between.
      exercised = MapSet.new(sites, & &1.mutator)

      for family <- ~w(operand_swap relational strict_equality arithmetic numeric atom logical)a do
        assert family in exercised, "fixture produced no #{family} mutant"
      end

      shared =
        sites
        |> Enum.group_by(&{&1.line, &1.column, &1.mutated_code}, & &1.mutator)
        |> Enum.filter(fn {_position, families} -> length(Enum.uniq(families)) > 1 end)
        |> Enum.sort()

      assert shared == [],
             "the same mutant is emitted by more than one family: #{inspect(shared, pretty: true)}"
    end
  end
end
