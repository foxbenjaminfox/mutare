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
    StringCall,
    StringLiteral,
    TupleLiteral,
    WordListLiteral
  }

  describe "registry (single source of truth)" do
    test "all/0 is every registered module, in order — the default/`:all` set" do
      assert Mutators.all() == Keyword.values(Mutators.registry())

      assert Mutators.all() ==
               [Arithmetic, OperandSwap, Relational, Logical, Literal, Conditional, IfCondition] ++
                 [List] ++
                 [Collection, CollectionArity, StringCall, MapKeyword, Mutare.Mutators.MapSet] ++
                 [CallRemoval, DefaultDrop] ++
                 [ModeSwap, Numeric, Math, Integer, StringLiteral, FloatLiteral, AtomLiteral] ++
                 [CharlistLiteral, WordListLiteral, MapLiteral, TupleLiteral, BitstringLiteral] ++
                 [RegexLiteral, DateTimeLiteral, AliasLiteral, ReturnValue, PatternSwap] ++
                 [PatternWildcard, RescueType, GuardDrop]
    end

    test "families/0 are the registry's keys, in order — all on by default" do
      assert Mutators.families() == Keyword.keys(Mutators.registry())

      assert Mutators.families() ==
               [:arithmetic, :operand_swap, :relational, :logical, :literal, :conditional] ++
                 [:if_condition, :list] ++
                 [:collection, :collection_arity, :string_call, :map_keyword, :map_set] ++
                 [:call_removal] ++
                 [:default_drop, :mode_swap, :numeric, :math, :integer, :string, :float] ++
                 [:atom, :charlist, :word_list, :map, :tuple, :bitstring, :regex] ++
                 [
                   :datetime,
                   :alias,
                   :return_value,
                   :pattern_swap,
                   :pattern_wildcard,
                   :rescue_type,
                   :guard_drop
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
      assert message =~ "missing mutate/1"
    end

    test "resolve/1 reports a non-atom entry rather than crashing on a guard" do
      assert_raise ArgumentError, ~r/unknown mutator "Arithmetic"/, fn ->
        Mutators.resolve(["Arithmetic"])
      end
    end
  end

  describe "Arithmetic" do
    test "swaps binary arithmetic operators" do
      assert Arithmetic.mutate({:+, [], [1, 2]}) == [{:-, [], [1, 2]}]
      assert Arithmetic.mutate({:-, [], [1, 2]}) == [{:+, [], [1, 2]}]
      assert Arithmetic.mutate({:*, [], [1, 2]}) == [{:/, [], [1, 2]}]
      assert Arithmetic.mutate({:/, [], [1, 2]}) == [{:*, [], [1, 2]}]
    end

    test "swaps div/rem (call form) only at effective arity 2, pipe-aware" do
      # div/rem are bare Kernel calls handled in mutate/2 (mutate/1 skips them).
      assert Arithmetic.mutate({:div, [], [1, 2]}) == :skip
      assert Arithmetic.mutate({:div, [], [1, 2]}, %{pipe_mode: :unpiped}) == [{:rem, [], [1, 2]}]
      assert Arithmetic.mutate({:rem, [], [1, 2]}, %{pipe_mode: :unpiped}) == [{:div, [], [1, 2]}]

      # Piped: the stage carries one fewer arg (`x |> div(2)` is div/2), so a 1-arg
      # node at piped effective-arity 2 still swaps (the rename keeps the arg list).
      assert Arithmetic.mutate({:div, [], [2]}, %{pipe_mode: :piped}) == [{:rem, [], [2]}]

      # A same-named user call at another arity is left alone (not Kernel's div/2).
      assert Arithmetic.mutate({:div, [], [1, 2, 3]}, %{pipe_mode: :unpiped}) == :skip
      assert Arithmetic.mutate({:div, [], [2]}, %{pipe_mode: :unpiped}) == :skip
    end

    test "preserves operand AST and operator metadata" do
      meta = [line: 7, column: 3]
      operands = [{:a, [], nil}, {:b, [], nil}]
      assert Arithmetic.mutate({:+, meta, operands}) == [{:-, meta, operands}]
    end

    test "strips unary minus (arity 1): -x → x" do
      assert Arithmetic.mutate({:-, [], [{:x, [], nil}]}) == [{:x, [], nil}]
    end

    test "skips unary minus on a literal zero (-0 == 0 is equivalent)" do
      assert Arithmetic.mutate({:-, [], [0]}) == :skip
      assert Arithmetic.mutate({:-, [], [{:__block__, [token: "0"], [0]}]}) == :skip
    end

    test "skips non-arithmetic nodes" do
      assert Arithmetic.mutate({:>, [], [1, 2]}) == :skip
      assert Arithmetic.mutate({:foo, [], [1, 2]}) == :skip
      assert Arithmetic.mutate(42) == :skip
      assert Arithmetic.mutate({:x, [], nil}) == :skip
    end

    test "name" do
      assert Arithmetic.name() == :arithmetic
    end

    test "skips a multiplicative identity right operand (a * 1, a / 1)" do
      a = {:a, [], nil}

      assert Arithmetic.mutate({:*, [], [a, 1]}) == :skip
      assert Arithmetic.mutate({:/, [], [a, 1]}) == :skip
    end

    test "recognizes Sourceror-wrapped literal operands" do
      a = {:a, [], nil}
      one = {:__block__, [token: "1"], [1]}

      assert Arithmetic.mutate({:*, [], [a, one]}) == :skip
      assert Arithmetic.mutate({:/, [], [a, one]}) == :skip
    end

    test "for * and /, only the right operand is an identity (1 * a is a reciprocal)" do
      a = {:a, [], nil}

      assert Arithmetic.mutate({:*, [], [1, a]}) == [{:/, [], [1, a]}]
      assert Arithmetic.mutate({:/, [], [1, a]}) == [{:*, [], [1, a]}]
    end

    test "DOES mutate additive identity (+ 0 / - 0): -0.0 normalization is testable behavior" do
      a = {:a, [], nil}

      assert Arithmetic.mutate({:+, [], [a, 0]}) == [{:-, [], [a, 0]}]
      assert Arithmetic.mutate({:-, [], [a, 0]}) == [{:+, [], [a, 0]}]
    end

    test "div/rem are never treated as identity (rem(a, 1) is 0, not a)" do
      a = {:a, [], nil}
      assert Arithmetic.mutate({:div, [], [a, 1]}, %{pipe_mode: :unpiped}) == [{:rem, [], [a, 1]}]
      assert Arithmetic.mutate({:rem, [], [a, 1]}, %{pipe_mode: :unpiped}) == [{:div, [], [a, 1]}]
    end

    test "a non-identity literal (e.g. * 2) still mutates" do
      a = {:a, [], nil}
      assert Arithmetic.mutate({:*, [], [a, 2]}) == [{:/, [], [a, 2]}]
    end
  end

  describe "Relational" do
    test "ordering operators mutate to boundary neighbour and direction flip" do
      assert Relational.mutate({:>, [], [1, 2]}) == [{:>=, [], [1, 2]}, {:<, [], [1, 2]}]
      assert Relational.mutate({:>=, [], [1, 2]}) == [{:>, [], [1, 2]}, {:<=, [], [1, 2]}]
      assert Relational.mutate({:<, [], [1, 2]}) == [{:<=, [], [1, 2]}, {:>, [], [1, 2]}]
      assert Relational.mutate({:<=, [], [1, 2]}) == [{:<, [], [1, 2]}, {:>=, [], [1, 2]}]
    end

    test "equality operators flip polarity" do
      assert Relational.mutate({:==, [], [1, 2]}) == [{:!=, [], [1, 2]}]
      assert Relational.mutate({:!=, [], [1, 2]}) == [{:==, [], [1, 2]}]
      assert Relational.mutate({:===, [], [1, 2]}) == [{:!==, [], [1, 2]}]
      assert Relational.mutate({:!==, [], [1, 2]}) == [{:===, [], [1, 2]}]
    end

    test "skips non-relational nodes" do
      assert Relational.mutate({:+, [], [1, 2]}) == :skip
      assert Relational.mutate({:x, [], nil}) == :skip
      assert Relational.mutate(:atom) == :skip
    end

    test "name" do
      assert Relational.name() == :relational
    end
  end

  describe "Logical" do
    test "swaps the strict and relaxed boolean connectives" do
      l = {:a, [], nil}
      r = {:b, [], nil}
      assert Logical.mutate({:and, [], [l, r]}) == [{:or, [], [l, r]}]
      assert Logical.mutate({:or, [], [l, r]}) == [{:and, [], [l, r]}]
      assert Logical.mutate({:&&, [], [l, r]}) == [{:||, [], [l, r]}]
      assert Logical.mutate({:||, [], [l, r]}) == [{:&&, [], [l, r]}]
    end

    test "strips a negation: not x → x and !x → x" do
      x = {:x, [], nil}
      assert Logical.mutate({:not, [], [x]}) == [x]
      assert Logical.mutate({:!, [], [x]}) == [x]
    end

    test "skips non-logical nodes" do
      assert Logical.mutate({:+, [], [1, 2]}) == :skip
      assert Logical.mutate({:x, [], nil}) == :skip
    end

    test "name" do
      assert Logical.name() == :logical
    end
  end

  describe "Literal" do
    test "mutates an integer to n+1, n-1 and 0, deduped and never itself" do
      assert render(Literal.mutate(parse("2"))) == ["3", "1", "0"]
      assert render(Literal.mutate(parse("1"))) == ["2", "0"]
      assert render(Literal.mutate(parse("0"))) == ["1", "-1"]
    end

    test "flips a boolean" do
      assert render(Literal.mutate(parse("true"))) == ["false"]
      assert render(Literal.mutate(parse("false"))) == ["true"]
    end

    test "emits clean metadata so the new value renders (not the original token)" do
      # The original carries `token: \"1\"`; reusing it would render \"1\".
      assert render(Literal.mutate(parse("1"))) == ["2", "0"]
      assert Enum.all?(Literal.mutate(parse("1")), fn {:__block__, meta, _} -> meta == [] end)
    end

    test "skips non-integer, non-boolean literals and operators" do
      assert Literal.mutate(parse("1.5")) == :skip
      assert Literal.mutate(parse(~s("s"))) == :skip
      assert Literal.mutate({:+, [], [1, 2]}) == :skip
    end

    test "name" do
      assert Literal.name() == :literal
    end
  end

  describe "Conditional" do
    test "replaces a boolean-valued node with the constants true and false" do
      assert render(Conditional.mutate(parse("a > b"))) == ["true", "false"]
      assert render(Conditional.mutate(parse("a == b"))) == ["true", "false"]
      assert render(Conditional.mutate(parse("a in b"))) == ["true", "false"]
      assert render(Conditional.mutate(parse("a and b"))) == ["true", "false"]
      assert render(Conditional.mutate(parse("not a"))) == ["true", "false"]
    end

    test "skips nodes that are not boolean-valued" do
      assert Conditional.mutate(parse("a + b")) == :skip
      assert Conditional.mutate(parse("1")) == :skip
    end

    test "name" do
      assert Conditional.name() == :conditional
    end
  end

  describe "List" do
    test "swaps ++ and --" do
      l = {:a, [], nil}
      r = {:b, [], nil}
      assert List.mutate({:++, [], [l, r]}) == [{:--, [], [l, r]}]
      assert List.mutate({:--, [], [l, r]}) == [{:++, [], [l, r]}]
    end

    test "collapses a non-empty list literal to []" do
      assert render(List.mutate(parse("[1, 2, 3]"))) == ["[]"]
      assert render(List.mutate(parse("[a | b]"))) == ["[]"]
    end

    test "leaves an empty list literal alone" do
      assert List.mutate(parse("[]")) == :skip
    end

    test "name" do
      assert List.name() == :list
    end
  end

  describe "Collection" do
    test "swaps complementary Enum/List calls, keeping arguments" do
      assert render(Collection.mutate(parse("Enum.filter(xs, f)"))) == ["Enum.reject(xs, f)"]
      assert render(Collection.mutate(parse("Enum.reject(xs, f)"))) == ["Enum.filter(xs, f)"]
      assert render(Collection.mutate(parse("Enum.all?(xs, f)"))) == ["Enum.any?(xs, f)"]
      assert render(Collection.mutate(parse("Enum.min(xs)"))) == ["Enum.max(xs)"]
      assert render(Collection.mutate(parse("List.first(xs)"))) == ["List.last(xs)"]
    end

    test "swaps the additional Enum/List pairs, keeping arguments" do
      assert render(Collection.mutate(parse("Enum.min_by(xs, f)"))) == ["Enum.max_by(xs, f)"]
      assert render(Collection.mutate(parse("Enum.max_by(xs, f)"))) == ["Enum.min_by(xs, f)"]

      assert render(Collection.mutate(parse("Enum.take_while(xs, f)"))) ==
               ["Enum.drop_while(xs, f)"]

      assert render(Collection.mutate(parse("Enum.drop_while(xs, f)"))) ==
               ["Enum.take_while(xs, f)"]

      assert render(Collection.mutate(parse("Enum.take_every(xs, n)"))) ==
               ["Enum.drop_every(xs, n)"]

      assert render(Collection.mutate(parse("Enum.drop_every(xs, n)"))) ==
               ["Enum.take_every(xs, n)"]

      assert render(Collection.mutate(parse("Enum.sum(xs)"))) == ["Enum.product(xs)"]
      assert render(Collection.mutate(parse("Enum.product(xs)"))) == ["Enum.sum(xs)"]

      assert render(Collection.mutate(parse("List.foldl(xs, acc, f)"))) ==
               ["List.foldr(xs, acc, f)"]

      assert render(Collection.mutate(parse("List.foldr(xs, acc, f)"))) ==
               ["List.foldl(xs, acc, f)"]
    end

    test "swaps the lazy Stream twins of the directional Enum pairs" do
      assert render(Collection.mutate(parse("Stream.filter(xs, f)"))) == ["Stream.reject(xs, f)"]
      assert render(Collection.mutate(parse("Stream.reject(xs, f)"))) == ["Stream.filter(xs, f)"]
      assert render(Collection.mutate(parse("Stream.take(xs, n)"))) == ["Stream.drop(xs, n)"]
      assert render(Collection.mutate(parse("Stream.drop(xs, n)"))) == ["Stream.take(xs, n)"]

      assert render(Collection.mutate(parse("Stream.take_while(xs, f)"))) ==
               ["Stream.drop_while(xs, f)"]

      assert render(Collection.mutate(parse("Stream.drop_while(xs, f)"))) ==
               ["Stream.take_while(xs, f)"]

      assert render(Collection.mutate(parse("Stream.take_every(xs, n)"))) ==
               ["Stream.drop_every(xs, n)"]

      assert render(Collection.mutate(parse("Stream.drop_every(xs, n)"))) ==
               ["Stream.take_every(xs, n)"]
    end

    test "skips unrelated remote calls and other modules' functions" do
      assert Collection.mutate(parse("Enum.map(xs, f)")) == :skip
      assert Collection.mutate(parse("Other.filter(xs, f)")) == :skip
      assert Collection.mutate(parse("local(xs)")) == :skip
      # Stream has no eager reducers, so those have no lazy twin to swap to.
      assert Collection.mutate(parse("Stream.map(xs, f)")) == :skip
      assert Collection.mutate(parse("Stream.into(xs, %{})")) == :skip
    end

    test "name" do
      assert Collection.name() == :collection
    end
  end

  describe "CollectionArity" do
    test "never fires node-locally (mutate/1 is always :skip)" do
      assert CollectionArity.mutate(parse("Enum.sort(xs, f)")) == :skip
      assert CollectionArity.mutate(parse("Enum.reverse(xs)")) == :skip
    end

    test "sort/sort_by collapse to reverse, dropping refining args (non-piped)" do
      assert arity("Enum.sort(xs)", false) == ["Enum.reverse(xs)"]
      assert arity("Enum.sort(xs, :desc)", false) == ["Enum.reverse(xs)"]
      assert arity("Enum.reverse(xs)", false) == ["Enum.sort(xs)"]
      assert arity("Enum.sort_by(xs, key)", false) == ["Enum.reverse(xs)"]
      assert arity("Enum.sort_by(xs, key, sorter)", false) == ["Enum.reverse(xs)"]
    end

    test "count/count_until drop their predicate (non-piped)" do
      assert arity("Enum.count(xs, p)", false) == ["Enum.count(xs)"]
      assert arity("Enum.count_until(xs, fun, lim)", false) == ["Enum.count_until(xs, lim)"]
    end

    test "piped: effective arity is +1, so the visible-arg-stripping shifts" do
      # `xs |> Enum.sort(:desc)` reaches us as a 1-arg node, effective arity 2 →
      # drop the comparator, leaving a 0-arg stage the pipe feeds.
      assert arity("Enum.sort(:desc)", true) == ["Enum.reverse()"]
      assert arity("Enum.sort()", true) == ["Enum.reverse()"]
      assert arity("Enum.count(p)", true) == ["Enum.count()"]
      assert arity("Enum.count_until(fun, lim)", true) == ["Enum.count_until(lim)"]
      assert arity("Enum.sort_by(key)", true) == ["Enum.reverse()"]
    end

    test "reverse/2 is reverse(list, tail) — an unrelated op — never mutated, piped or not" do
      assert CollectionArity.mutate(parse("Enum.reverse(xs, tail)"), %{pipe_mode: :unpiped}) ==
               :skip

      # piped reverse/2: 1 visible arg, effective arity 2 — still recognised and skipped
      assert CollectionArity.mutate(parse("Enum.reverse(tail)"), %{pipe_mode: :piped}) == :skip
    end

    test "skips functions with nothing to drop, and other modules" do
      assert CollectionArity.mutate(parse("Enum.count(xs)"), %{pipe_mode: :unpiped}) == :skip
      assert CollectionArity.mutate(parse("Enum.map(xs, f)"), %{pipe_mode: :unpiped}) == :skip
      assert CollectionArity.mutate(parse("List.sort(xs, f)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "name" do
      assert CollectionArity.name() == :collection_arity
    end
  end

  describe "StringCall" do
    test "swaps complementary String calls, keeping arguments" do
      assert render(StringCall.mutate(parse(~s|String.starts_with?(s, p)|))) ==
               [~s|String.ends_with?(s, p)|]

      assert render(StringCall.mutate(parse(~s|String.ends_with?(s, p)|))) ==
               [~s|String.starts_with?(s, p)|]

      assert render(StringCall.mutate(parse("String.upcase(s)"))) == ["String.downcase(s)"]
      assert render(StringCall.mutate(parse("String.downcase(s)"))) == ["String.upcase(s)"]

      assert render(StringCall.mutate(parse("String.trim_leading(s)"))) ==
               ["String.trim_trailing(s)"]

      assert render(StringCall.mutate(parse("String.replace_prefix(s, m, r)"))) ==
               ["String.replace_suffix(s, m, r)"]

      assert render(StringCall.mutate(parse("String.pad_leading(s, 8)"))) ==
               ["String.pad_trailing(s, 8)"]

      assert render(StringCall.mutate(parse("String.first(s)"))) == ["String.last(s)"]
      assert render(StringCall.mutate(parse("String.last(s)"))) == ["String.first(s)"]

      assert render(StringCall.mutate(parse("String.replace_leading(s, m, r)"))) ==
               ["String.replace_trailing(s, m, r)"]

      assert render(StringCall.mutate(parse("String.replace_trailing(s, m, r)"))) ==
               ["String.replace_leading(s, m, r)"]

      assert render(StringCall.mutate(parse("String.graphemes(s)"))) == ["String.codepoints(s)"]
      assert render(StringCall.mutate(parse("String.codepoints(s)"))) == ["String.graphemes(s)"]
    end

    test "preserves arguments and metadata of multi-arity calls" do
      assert render(StringCall.mutate(parse("String.upcase(s, :ascii)"))) ==
               ["String.downcase(s, :ascii)"]

      assert render(StringCall.mutate(parse("String.pad_leading(s, 8, \"0\")"))) ==
               ["String.pad_trailing(s, 8, \"0\")"]
    end

    test "substitutes String.equivalent?(a, b) with raw == (dropping normalization)" do
      assert render(StringCall.mutate(parse("String.equivalent?(a, b)"))) == ["a == b"]

      assert render(StringCall.mutate(parse(~s|String.equivalent?(x, "foo")|))) == [
               ~s|x == "foo"|
             ]

      # a 1-arg call is only reachable as a `|>` stage — becomes `a |> Kernel.==(b)`
      assert render(StringCall.mutate(parse("String.equivalent?(b)"))) == ["Kernel.==(b)"]
    end

    test "swaps the Erlang :string directional/case pairs" do
      assert render(StringCall.mutate(parse(":string.uppercase(s)"))) == [":string.lowercase(s)"]
      assert render(StringCall.mutate(parse(":string.lowercase(s)"))) == [":string.uppercase(s)"]
      assert render(StringCall.mutate(parse(":string.to_upper(s)"))) == [":string.to_lower(s)"]
      assert render(StringCall.mutate(parse(":string.to_lower(s)"))) == [":string.to_upper(s)"]
      assert render(StringCall.mutate(parse(":string.left(s, 8)"))) == [":string.right(s, 8)"]

      assert render(StringCall.mutate(parse(":string.right(s, 8, ?0)"))) == [
               ":string.left(s, 8, ?0)"
             ]
    end

    test "swaps the Erlang :binary first/last pair (the byte-level String.first/last twin)" do
      assert render(StringCall.mutate(parse(":binary.first(b)"))) == [":binary.last(b)"]
      assert render(StringCall.mutate(parse(":binary.last(b)"))) == [":binary.first(b)"]
      # other :binary functions have no directional twin
      assert StringCall.mutate(parse(":binary.match(b, p)")) == :skip
      assert StringCall.mutate(parse(":binary.part(b, 0, 2)")) == :skip
    end

    test "skips unrelated String functions and other modules' calls" do
      assert StringCall.mutate(parse("String.length(s)")) == :skip
      assert StringCall.mutate(parse("String.split(s, \",\")")) == :skip
      assert StringCall.mutate(parse("Path.starts_with?(s, p)")) == :skip
      assert StringCall.mutate(parse("starts_with?(s, p)")) == :skip
      # :string functions without a directional twin (`centre` has no opposite),
      # and other Erlang modules
      assert StringCall.mutate(parse(":string.centre(s, 8)")) == :skip
      assert StringCall.mutate(parse(":string.length(s)")) == :skip
      assert StringCall.mutate(parse(":unicode.characters_to_binary(s)")) == :skip
    end

    test "name" do
      assert StringCall.name() == :string_call
    end
  end

  describe "MapKeyword" do
    test "swaps along the conditional-write lattice (Map), keeping arguments" do
      assert render(MapKeyword.mutate(parse("Map.put(m, k, v)"))) ==
               ["Map.put_new(m, k, v)", "Map.replace(m, k, v)"]

      assert render(MapKeyword.mutate(parse("Map.put_new(m, k, v)"))) ==
               ["Map.put(m, k, v)", "Map.replace(m, k, v)"]

      assert render(MapKeyword.mutate(parse("Map.replace(m, k, v)"))) ==
               ["Map.put(m, k, v)", "Map.put_new(m, k, v)", "Map.replace!(m, k, v)"]

      assert render(MapKeyword.mutate(parse("Map.replace!(m, k, v)"))) ==
               ["Map.replace(m, k, v)"]
    end

    test "the same lattice applies to Keyword" do
      assert render(MapKeyword.mutate(parse("Keyword.put(kw, k, v)"))) ==
               ["Keyword.put_new(kw, k, v)", "Keyword.replace(kw, k, v)"]

      assert render(MapKeyword.mutate(parse("Keyword.replace!(kw, k, v)"))) ==
               ["Keyword.replace(kw, k, v)"]
    end

    test "skips unrelated functions and other modules" do
      assert MapKeyword.mutate(parse("Map.delete(m, k)")) == :skip
      assert MapKeyword.mutate(parse("Map.put_new_lazy(m, k, f)")) == :skip
      assert MapKeyword.mutate(parse("Map.update!(m, k, f)")) == :skip
      assert MapKeyword.mutate(parse("Other.put(m, k, v)")) == :skip
      assert MapKeyword.mutate(parse("put(m, k, v)")) == :skip
    end

    test "name" do
      assert MapKeyword.name() == :map_keyword
    end
  end

  describe "CallRemoval" do
    test "never fires node-locally (mutate/1 is always :skip)" do
      assert CallRemoval.mutate(parse("Enum.sort(xs)")) == :skip
      assert CallRemoval.mutate(parse("String.trim(s)")) == :skip
    end

    test "non-piped: drops the transform, returning its first argument" do
      assert removal("Enum.sort(xs)", false) == ["xs"]
      assert removal("Enum.sort(xs, :desc)", false) == ["xs"]
      assert removal("Enum.reverse(xs)", false) == ["xs"]
      assert removal("Enum.uniq_by(xs, f)", false) == ["xs"]
      assert removal("Enum.intersperse(xs, 0)", false) == ["xs"]
      # The lazy Stream twins — same transparent transforms, returning their input.
      assert removal("Stream.uniq(xs)", false) == ["xs"]
      assert removal("Stream.uniq_by(xs, f)", false) == ["xs"]
      assert removal("Stream.dedup(xs)", false) == ["xs"]
      assert removal("Stream.dedup_by(xs, f)", false) == ["xs"]
      assert removal("Stream.intersperse(xs, 0)", false) == ["xs"]
      assert removal("List.flatten(xs)", false) == ["xs"]
      assert removal("String.trim(s)", false) == ["s"]
      assert removal("String.downcase(s)", false) == ["s"]
      # The newer string transforms — reorder, normalize, sanitize, pad.
      assert removal("String.reverse(s)", false) == ["s"]
      assert removal("String.normalize(s, :nfc)", false) == ["s"]
      assert removal("String.replace_invalid(s)", false) == ["s"]
      assert removal("String.pad_leading(s, 5)", false) == ["s"]
      assert removal("String.pad_trailing(s, 5, \"x\")", false) == ["s"]
      # slice selects a part; removing it returns the whole input ("was the slice exercised?")
      assert removal("String.slice(s, 1, 3)", false) == ["s"]
      assert removal("String.slice(s, 1..3)", false) == ["s"]
      # URI form-encoding (binary -> binary) and the NaiveDateTime day-boundary
      # normalizers — same-typed transforms whose removal returns the input.
      assert removal("URI.encode_www_form(s)", false) == ["s"]
      assert removal("URI.decode_www_form(s)", false) == ["s"]
      assert removal("NaiveDateTime.beginning_of_day(n)", false) == ["n"]
      assert removal("NaiveDateTime.end_of_day(n)", false) == ["n"]
      # Date period-boundary normalizers — Date -> Date, so removal returns the input date.
      assert removal("Date.beginning_of_month(d)", false) == ["d"]
      assert removal("Date.end_of_month(d)", false) == ["d"]
      assert removal("Date.beginning_of_week(d)", false) == ["d"]
      assert removal("Date.end_of_week(d, :sunday)", false) == ["d"]
    end

    test "removes the analogous Erlang :string transparent transforms" do
      # case, trim, reverse, pad/justify, substring-select — each returns its input
      assert removal(":string.lowercase(s)", false) == ["s"]
      assert removal(":string.to_upper(s)", false) == ["s"]
      assert removal(":string.titlecase(s)", false) == ["s"]
      assert removal(":string.casefold(s)", false) == ["s"]
      assert removal(":string.trim(s)", false) == ["s"]
      assert removal(":string.strip(s, :both)", false) == ["s"]
      assert removal(":string.chomp(s)", false) == ["s"]
      assert removal(":string.reverse(s)", false) == ["s"]
      assert removal(":string.pad(s, 8)", false) == ["s"]
      assert removal(":string.left(s, 8)", false) == ["s"]
      assert removal(":string.centre(s, 8)", false) == ["s"]
      assert removal(":string.slice(s, 1, 3)", false) == ["s"]
      assert removal(":string.substr(s, 2)", false) == ["s"]
      assert removal(":string.sub_string(s, 2, 4)", false) == ["s"]
      # piped: a no-op stage the pipe feeds
      assert removal(":string.slice(1, 3)", true) == ["Function.identity()"]
    end

    test "excludes content-changing / non-transform String and :string calls" do
      assert CallRemoval.mutate(parse("String.replace(s, a, b)"), %{pipe_mode: :unpiped}) == :skip
      assert CallRemoval.mutate(parse("String.first(s)"), %{pipe_mode: :unpiped}) == :skip
      assert CallRemoval.mutate(parse("String.split(s, \",\")"), %{pipe_mode: :unpiped}) == :skip
      # :string — split/replace change content; prefix can return :nomatch; other modules
      assert CallRemoval.mutate(parse(":string.split(s, \",\")"), %{pipe_mode: :unpiped}) == :skip

      assert CallRemoval.mutate(parse(":string.replace(s, a, b)"), %{pipe_mode: :unpiped}) ==
               :skip

      assert CallRemoval.mutate(parse(":string.prefix(s, p)"), %{pipe_mode: :unpiped}) == :skip
      assert CallRemoval.mutate(parse(":lists.reverse(s)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "piped: replaces the stage with Function.identity() (a no-op the pipe feeds)" do
      # `x |> Enum.sort(:desc)` reaches us as a 1-arg node; the piped flag means the
      # input is the |> LHS, so we must NOT return the comparator — identity instead.
      assert removal("Enum.sort()", true) == ["Function.identity()"]
      assert removal("Enum.sort(:desc)", true) == ["Function.identity()"]
      assert removal("String.trim()", true) == ["Function.identity()"]
      assert removal("Enum.uniq()", true) == ["Function.identity()"]
      assert removal("Enum.intersperse(0)", true) == ["Function.identity()"]
      # `s |> String.normalize(:nfc)` — the form is the LHS-less visible arg, so we
      # must return identity, never the `:nfc` atom.
      assert removal("String.normalize(:nfc)", true) == ["Function.identity()"]
      assert removal("String.pad_leading(5)", true) == ["Function.identity()"]
      assert removal("String.slice(1, 3)", true) == ["Function.identity()"]
      assert removal("URI.encode_www_form()", true) == ["Function.identity()"]
      assert removal("NaiveDateTime.beginning_of_day()", true) == ["Function.identity()"]
    end

    test "excludes map/filter/reduce and unrelated calls" do
      assert CallRemoval.mutate(parse("Enum.map(xs, f)"), %{pipe_mode: :unpiped}) == :skip
      assert CallRemoval.mutate(parse("Enum.filter(xs, f)"), %{pipe_mode: :unpiped}) == :skip
      assert CallRemoval.mutate(parse("Enum.reduce(xs, 0, f)"), %{pipe_mode: :unpiped}) == :skip
      assert CallRemoval.mutate(parse("Other.sort(xs)"), %{pipe_mode: :unpiped}) == :skip
      assert CallRemoval.mutate(parse("local(xs)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "bare Kernel abs/1 is removed, leaving its argument" do
      assert removal("abs(x)", false) == ["x"]
      assert removal("abs(a - b)", false) == ["a - b"]
      # Piped `value |> abs()` — 0 visible args, effective arity 1 → identity.
      assert removal("abs()", true) == ["Function.identity()"]
    end

    test "qualified Kernel.abs is removed arity-blind (the prefix proves it)" do
      assert removal("Kernel.abs(x)", false) == ["x"]
      assert removal("Kernel.abs()", true) == ["Function.identity()"]
    end

    test "the Kernel binary slicers are removed, returning the whole binary" do
      # Bare — keyed on effective arity (binary_slice/2,/3 and binary_part/3 exist).
      assert removal("binary_slice(b, 0, 5)", false) == ["b"]
      assert removal("binary_slice(b, 0..4)", false) == ["b"]
      assert removal("binary_part(b, 0, 5)", false) == ["b"]
      # Piped — the LHS-less stage becomes a no-op the pipe feeds.
      assert removal("binary_slice(0..4)", true) == ["Function.identity()"]
      assert removal("binary_part(0, 5)", true) == ["Function.identity()"]
      # Qualified Kernel — arity-blind (the prefix proves the function).
      assert removal("Kernel.binary_slice(b, r)", false) == ["b"]
      assert removal("Kernel.binary_part(b, 0, 5)", false) == ["b"]
    end

    test "binary_part/2 (only :erlang.binary_part/2) is removed via its Erlang form" do
      # `binary_part/2` is not a Kernel function — its sole incarnation is
      # `:erlang.binary_part(bin, {start, len})`. Removed arity-blind like :string.
      assert removal(":erlang.binary_part(b, {0, 5})", false) == ["b"]
      assert removal(":erlang.binary_part(b, 0, 5)", false) == ["b"]
      assert removal(":erlang.binary_part({0, 5})", true) == ["Function.identity()"]
    end

    test "a same-named binary slicer at the wrong bare arity is left alone" do
      # No bare Kernel binary_slice/1 or binary_part/2 — so these must be user funcs.
      assert CallRemoval.mutate(parse("binary_slice(b)"), %{pipe_mode: :unpiped}) == :skip
      assert CallRemoval.mutate(parse("binary_part(b, {0, 5})"), %{pipe_mode: :unpiped}) == :skip
    end

    test "a same-named call at the wrong arity is left alone (arity guards bare abs)" do
      # No Kernel.abs/2 or /0 — so these must be user functions, untouched.
      assert CallRemoval.mutate(parse("abs(x, y)"), %{pipe_mode: :unpiped}) == :skip
      assert CallRemoval.mutate(parse("abs()"), %{pipe_mode: :unpiped}) == :skip
      # Piped `abs(x)` would be effective arity 2 — not the Kernel abs/1.
      assert CallRemoval.mutate(parse("abs(x)"), %{pipe_mode: :piped}) == :skip
    end

    test "abs never fires node-locally (mutate/1 is always :skip)" do
      assert CallRemoval.mutate(parse("abs(x)")) == :skip
    end

    test "name" do
      assert CallRemoval.name() == :call_removal
    end
  end

  describe "DefaultDrop" do
    test "never fires node-locally (mutate/1 is always :skip)" do
      assert DefaultDrop.mutate(parse("Map.get(m, k, :d)")) == :skip
    end

    test "non-piped: drops a non-nil trailing default, reverting to the /2 lookup" do
      assert dropd("Map.get(m, k, :default)", false) == ["Map.get(m, k)"]
      assert dropd("Keyword.get(kw, k, 0)", false) == ["Keyword.get(kw, k)"]
      assert dropd("Map.pop(m, k, :d)", false) == ["Map.pop(m, k)"]
      assert dropd("Enum.at(xs, i, :none)", false) == ["Enum.at(xs, i)"]
      assert dropd("List.first(xs, :empty)", false) == ["List.first(xs)"]
      assert dropd("List.last(xs, :empty)", false) == ["List.last(xs)"]
    end

    test "a literal nil default is skipped (equivalent — nil is the implicit default)" do
      assert DefaultDrop.mutate(parse("Map.get(m, k, nil)"), %{pipe_mode: :unpiped}) == :skip
      assert DefaultDrop.mutate(parse("Keyword.get(kw, k, nil)"), %{pipe_mode: :unpiped}) == :skip
      # but a non-nil falsy default (false, 0) is a real difference — still dropped.
      assert dropd("Map.get(m, k, false)", false) == ["Map.get(m, k)"]
      assert dropd("Map.get(m, k, 0)", false) == ["Map.get(m, k)"]
    end

    test "_lazy forms rename to the base lookup and drop the fallback fun" do
      assert dropd("Map.get_lazy(m, k, f)", false) == ["Map.get(m, k)"]
      assert dropd("Keyword.get_lazy(kw, k, f)", false) == ["Keyword.get(kw, k)"]
      assert dropd("Map.pop_lazy(m, k, f)", false) == ["Map.pop(m, k)"]
    end

    test "piped: effective arity is +1, so a /3 reaches us as 2 visible args" do
      # `m |> Map.get(k, :d)` — drop the trailing visible default, leaving the /2 stage.
      assert dropd("Map.get(k, :default)", true) == ["Map.get(k)"]
      assert dropd("List.first(:empty)", true) == ["List.first()"]
      assert dropd("Map.get_lazy(k, f)", true) == ["Map.get(k)"]
      # A piped nil default is still equivalent → skipped.
      assert DefaultDrop.mutate(parse("Map.get(k, nil)"), %{pipe_mode: :piped}) == :skip
    end

    test "a /2 lookup (no default) is not mutated — needs the piped flag to tell apart" do
      # non-piped Map.get/2: nothing to drop.
      assert DefaultDrop.mutate(parse("Map.get(m, k)"), %{pipe_mode: :unpiped}) == :skip
      # piped Map.get/2 (`m |> Map.get(k)`): also /2 effective, nothing to drop.
      assert DefaultDrop.mutate(parse("Map.get(k)"), %{pipe_mode: :piped}) == :skip
    end

    test "skips unrelated functions and modules" do
      assert DefaultDrop.mutate(parse("Map.fetch(m, k)"), %{pipe_mode: :unpiped}) == :skip
      assert DefaultDrop.mutate(parse("Other.get(m, k, :d)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "name" do
      assert DefaultDrop.name() == :default_drop
    end
  end

  describe "ModeSwap" do
    test "never fires node-locally (mutate/1 is always :skip)" do
      assert ModeSwap.mutate(parse("DateTime.truncate(dt, :second)")) == :skip
      assert ModeSwap.mutate(parse("String.upcase(s, :ascii)")) == :skip
    end

    test "truncate precision: swaps to adjacent ladder neighbours only (non-piped)" do
      # `:second` is an endpoint of {microsecond, millisecond, second} — one neighbour.
      assert mode("DateTime.truncate(dt, :second)", false) == [
               "DateTime.truncate(dt, :millisecond)"
             ]

      # `:millisecond` is interior — both neighbours, finer then coarser.
      assert mode("Time.truncate(t, :millisecond)", false) ==
               ["Time.truncate(t, :microsecond)", "Time.truncate(t, :second)"]

      assert mode("NaiveDateTime.truncate(n, :microsecond)", false) ==
               ["NaiveDateTime.truncate(n, :millisecond)"]
    end

    test "calendar unit (add/diff, arg 2) walks the full ladder, never escaping it" do
      assert mode("DateTime.add(dt, n, :minute)", false) ==
               ["DateTime.add(dt, n, :second)", "DateTime.add(dt, n, :hour)"]

      # `:day` is the coarse endpoint — one neighbour.
      assert mode("DateTime.diff(a, b, :day)", false) == ["DateTime.diff(a, b, :hour)"]
      assert mode("Time.add(t, n, :nanosecond)", false) == ["Time.add(t, n, :microsecond)"]
      # The optional 4th time-zone-database arg leaves the unit at position 2.
      assert mode("DateTime.add(dt, n, :second, tz)", false) ==
               ["DateTime.add(dt, n, :millisecond, tz)", "DateTime.add(dt, n, :minute, tz)"]
    end

    test "System clock units, including :native and convert_time_unit's two positions" do
      assert mode("System.system_time(:millisecond)", false) ==
               ["System.system_time(:microsecond)", "System.system_time(:second)"]

      # :native isn't on the magnitude ladder — mapped to a concrete unit.
      assert mode("System.monotonic_time(:native)", false) == ["System.monotonic_time(:second)"]

      # Both unit arguments are swapped, each independently.
      assert mode("System.convert_time_unit(t, :second, :millisecond)", false) ==
               [
                 "System.convert_time_unit(t, :millisecond, :millisecond)",
                 "System.convert_time_unit(t, :second, :microsecond)",
                 "System.convert_time_unit(t, :second, :second)"
               ]
    end

    test "shift duration: each unit key swaps to an adjacent ladder neighbour (non-piped)" do
      # interior unit → both neighbours; endpoint → one.
      assert mode("DateTime.shift(dt, minute: 10)", false) ==
               ["DateTime.shift(dt, second: 10)", "DateTime.shift(dt, hour: 10)"]

      assert mode("DateTime.shift(dt, year: 1)", false) == ["DateTime.shift(dt, month: 1)"]

      assert mode("NaiveDateTime.shift(n, week: 2)", false) ==
               ["NaiveDateTime.shift(n, day: 2)", "NaiveDateTime.shift(n, month: 2)"]
    end

    test "shift: each key in a multi-unit duration is swapped independently, amount kept" do
      assert mode("DateTime.shift(dt, minute: 10, day: -1)", false) == [
               "DateTime.shift(dt, second: 10, day: -1)",
               "DateTime.shift(dt, hour: 10, day: -1)",
               "DateTime.shift(dt, minute: 10, hour: -1)",
               "DateTime.shift(dt, minute: 10, week: -1)"
             ]
    end

    test "Time.shift uses the time-only ladder (no date units to escape to)" do
      assert mode("Time.shift(t, hour: 1)", false) == ["Time.shift(t, minute: 1)"]

      assert mode("Time.shift(t, minute: 1)", false) ==
               ["Time.shift(t, second: 1)", "Time.shift(t, hour: 1)"]

      # a date unit isn't on Time's ladder — no swap (Time.shift would reject it anyway).
      assert ModeSwap.mutate(parse("Time.shift(t, day: 1)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "Date.shift uses the date-only ladder (no time units to escape to)" do
      # `:day` is the fine endpoint of {day, week, month, year} — one neighbour.
      assert mode("Date.shift(d, day: 1)", false) == ["Date.shift(d, week: 1)"]

      assert mode("Date.shift(d, week: 2)", false) ==
               ["Date.shift(d, day: 2)", "Date.shift(d, month: 2)"]

      assert mode("Date.shift(d, year: 1)", false) == ["Date.shift(d, month: 1)"]

      # a time unit isn't on Date's ladder — no swap (Date.shift would reject it anyway).
      assert ModeSwap.mutate(parse("Date.shift(d, hour: 1)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "shift: :microsecond is excluded (its {count, precision} amount can't move units)" do
      assert ModeSwap.mutate(parse("DateTime.shift(dt, microsecond: {5, 6})"), %{
               pipe_mode: :unpiped
             }) ==
               :skip
    end

    test "shift/3: a bracketed duration before the opts still swaps, brackets preserved" do
      assert mode("DateTime.shift(dt, [minute: 10], time_zone_database: db)", false) == [
               "DateTime.shift(dt, [second: 10], time_zone_database: db)",
               "DateTime.shift(dt, [hour: 10], time_zone_database: db)"
             ]
    end

    test "shift: piped, the duration keyword list is the lone visible arg" do
      assert mode("DateTime.shift(minute: 10)", true) ==
               ["DateTime.shift(second: 10)", "DateTime.shift(hour: 10)"]
    end

    test "shift: a non-keyword-list duration (a %Duration{} / variable) yields nothing" do
      assert ModeSwap.mutate(parse("DateTime.shift(dt, dur)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "Unicode case mode: only the exotic locale modes fall back to :default" do
      assert mode("String.upcase(s, :greek)", false) == ["String.upcase(s, :default)"]
      assert mode("String.capitalize(s, :turkic)", false) == ["String.capitalize(s, :default)"]

      # `:default` ↔ `:ascii` is deliberately not swapped (a low-signal equivalent).
      assert ModeSwap.mutate(parse("String.upcase(s, :default)"), %{pipe_mode: :unpiped}) == :skip
      assert ModeSwap.mutate(parse("String.downcase(s, :ascii)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "normalization form swaps to a behavioural sibling" do
      assert mode("String.normalize(s, :nfc)", false) == ["String.normalize(s, :nfd)"]
      assert mode("String.normalize(s, :nfkd)", false) == ["String.normalize(s, :nfkc)"]
    end

    test "piped: effective arity is +1, so the mode atom is the lone visible arg" do
      # `dt |> DateTime.truncate(:second)` — effective arity 2, the precision at visible 0.
      assert mode("DateTime.truncate(:second)", true) == ["DateTime.truncate(:millisecond)"]

      assert mode("DateTime.add(n, :minute)", true) ==
               ["DateTime.add(n, :second)", "DateTime.add(n, :hour)"]

      assert mode("String.upcase(:greek)", true) == ["String.upcase(:default)"]
    end

    test "piped: a unit at effective position 0 (the piped value itself) yields nothing" do
      # `:millisecond |> System.system_time()` — the unit *is* the piped value, so its
      # effective position 0 maps to no visible arg (`visible_index/2` → nil) and the
      # call contributes no swap (rather than crashing on `Enum.at(args, nil)`).
      assert ModeSwap.mutate(parse("System.system_time()"), %{pipe_mode: :piped}) == :skip
    end

    test "a non-atom or unrecognised atom in the mode position yields nothing" do
      # A variable unit can't be swapped statically.
      assert ModeSwap.mutate(parse("DateTime.truncate(dt, unit)"), %{pipe_mode: :unpiped}) ==
               :skip

      # An integer parts-per-second unit is not an atom.
      assert ModeSwap.mutate(parse("System.system_time(1000)"), %{pipe_mode: :unpiped}) == :skip
      # An atom outside the function's legal set has no in-set neighbour.
      assert ModeSwap.mutate(parse("DateTime.truncate(dt, :bogus)"), %{pipe_mode: :unpiped}) ==
               :skip

      # An unrecognised atom in the *unordered* mode sets (case / normalization form)
      # also yields nothing — `swaps/2` falls back to `[]`, never `nil` (a `Map.get`
      # without its default would enumerate `nil` and crash).
      assert ModeSwap.mutate(parse("String.upcase(s, :bogus)"), %{pipe_mode: :unpiped}) == :skip

      assert ModeSwap.mutate(parse("String.normalize(s, :bogus)"), %{pipe_mode: :unpiped}) ==
               :skip
    end

    test "skips unrelated functions, arities, and modules" do
      # truncate/1 has no precision arg; add/2 has no unit (defaults to :second).
      assert ModeSwap.mutate(parse("DateTime.truncate(dt)"), %{pipe_mode: :unpiped}) == :skip
      assert ModeSwap.mutate(parse("DateTime.add(dt, n)"), %{pipe_mode: :unpiped}) == :skip

      assert ModeSwap.mutate(parse("Other.truncate(dt, :second)"), %{pipe_mode: :unpiped}) ==
               :skip

      assert ModeSwap.mutate(parse("String.split(s, p)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "name" do
      assert ModeSwap.name() == :mode_swap
    end
  end

  describe "Numeric" do
    test "Float.ceil ↔ Float.floor swap in mutate/1 (arity-blind rename)" do
      assert render(Numeric.mutate(parse("Float.ceil(x)"))) == ["Float.floor(x)"]
      assert render(Numeric.mutate(parse("Float.floor(x)"))) == ["Float.ceil(x)"]
      # Any arity — the /2 precision form renames too.
      assert render(Numeric.mutate(parse("Float.ceil(x, 2)"))) == ["Float.floor(x, 2)"]
      assert render(Numeric.mutate(parse("Float.floor(x, 2)"))) == ["Float.ceil(x, 2)"]
    end

    test "Float.round and unrelated Float/other calls are not swapped" do
      assert Numeric.mutate(parse("Float.round(x, 2)")) == :skip
      assert Numeric.mutate(parse("Float.to_string(x)")) == :skip
      assert Numeric.mutate(parse("Other.ceil(x)")) == :skip
    end

    test "Kernel-qualified calls swap in mutate/1 (arity-blind, qualifier proves it)" do
      assert render(Numeric.mutate(parse("Kernel.min(a, b)"))) == ["Kernel.max(a, b)"]
      assert render(Numeric.mutate(parse("Kernel.max(a, b)"))) == ["Kernel.min(a, b)"]
      assert render(Numeric.mutate(parse("Kernel.round(x)"))) == ["Kernel.trunc(x)"]
      assert render(Numeric.mutate(parse("Kernel.trunc(x)"))) == ["Kernel.round(x)"]
      assert render(Numeric.mutate(parse("Kernel.ceil(x)"))) == ["Kernel.floor(x)"]
      assert render(Numeric.mutate(parse("Kernel.floor(x)"))) == ["Kernel.ceil(x)"]
    end

    test "mutate/1 never fires on a bare Kernel call (those need effective arity)" do
      assert Numeric.mutate(parse("min(a, b)")) == :skip
      assert Numeric.mutate(parse("floor(x)")) == :skip
    end

    test "Kernel min ↔ max swap at arity 2 (non-piped)" do
      assert numeric("min(a, b)", false) == ["max(a, b)"]
      assert numeric("max(a, b)", false) == ["min(a, b)"]
    end

    test "Kernel round/trunc and ceil/floor swap as complementary pairs at arity 1" do
      assert numeric("round(x)", false) == ["trunc(x)"]
      assert numeric("trunc(x)", false) == ["round(x)"]
      assert numeric("ceil(x)", false) == ["floor(x)"]
      assert numeric("floor(x)", false) == ["ceil(x)"]
    end

    test "a same-named call at the wrong arity is left alone (arity guards the bare call)" do
      # No Kernel.min/3 or Kernel.floor/2 — so these must be user functions, untouched.
      assert Numeric.mutate(parse("min(a, b, c)"), %{pipe_mode: :unpiped}) == :skip
      assert Numeric.mutate(parse("floor(x, y)"), %{pipe_mode: :unpiped}) == :skip
      assert Numeric.mutate(parse("round(x, y)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "piped: effective arity is +1, so a piped /1 reaches us as 0 visible args" do
      # `x |> floor()` — 0 visible args, effective arity 1 → still swapped.
      assert numeric("floor()", true) == ["ceil()"]
      assert numeric("round()", true) == ["trunc()"]
      # `value |> max(0)` — 1 visible arg, effective arity 2 → the min/max pair.
      assert numeric("max(0)", true) == ["min(0)"]
      assert numeric("min(0)", true) == ["max(0)"]
    end

    test "piped /1 read non-piped (1 visible arg, effective arity 2) is not a min/max" do
      # `floor(x)` non-piped is arity 1 (swaps); piped it would be effective arity 2,
      # which floor has no rule for — so a piped floor/1-shaped node yields nothing.
      assert Numeric.mutate(parse("floor(x)"), %{pipe_mode: :piped}) == :skip
    end

    test "skips operators and non-numeric calls" do
      assert Numeric.mutate(parse("a + b"), %{pipe_mode: :unpiped}) == :skip
      assert Numeric.mutate(parse("foo(a, b)"), %{pipe_mode: :unpiped}) == :skip
      assert Numeric.mutate(parse("abs(x)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "name" do
      assert Numeric.name() == :numeric
    end
  end

  describe "Math" do
    test "co-function swaps (sin/cos, asin/acos, sinh/cosh, asinh/acosh)" do
      assert render(Math.mutate(parse(":math.sin(x)"))) == [":math.cos(x)"]
      assert render(Math.mutate(parse(":math.cos(x)"))) == [":math.sin(x)"]
      assert render(Math.mutate(parse(":math.asin(x)"))) == [":math.acos(x)"]
      assert render(Math.mutate(parse(":math.acos(x)"))) == [":math.asin(x)"]
      assert render(Math.mutate(parse(":math.sinh(x)"))) == [":math.cosh(x)"]
      assert render(Math.mutate(parse(":math.cosh(x)"))) == [":math.sinh(x)"]
      assert render(Math.mutate(parse(":math.asinh(x)"))) == [":math.acosh(x)"]
      assert render(Math.mutate(parse(":math.acosh(x)"))) == [":math.asinh(x)"]
    end

    test "the logarithm trio each maps to the other two bases" do
      assert render(Math.mutate(parse(":math.log(x)"))) == [":math.log2(x)", ":math.log10(x)"]
      assert render(Math.mutate(parse(":math.log2(x)"))) == [":math.log(x)", ":math.log10(x)"]
      assert render(Math.mutate(parse(":math.log10(x)"))) == [":math.log(x)", ":math.log2(x)"]
    end

    test "constants pi/tau become a nearby-but-wrong float literal" do
      assert render(Math.mutate(parse(":math.pi()"))) == ["3.0"]
      assert render(Math.mutate(parse(":math.tau()"))) == ["6.0"]
    end

    test "the constant swap only fires at arity 0" do
      # No `:math.pi/1` exists, but stay defensive: a same-named call with an
      # argument is never collapsed to the bare constant.
      assert Math.mutate(parse(":math.pi(x)")) == :skip
    end

    test "preserves the argument list on a rename" do
      assert render(Math.mutate(parse(":math.sin(a + b)"))) == [":math.cos(a + b)"]
    end

    test "skips :math functions outside the families and other atom modules" do
      assert Math.mutate(parse(":math.sqrt(x)")) == :skip
      assert Math.mutate(parse(":math.pow(x, y)")) == :skip
      assert Math.mutate(parse(":lists.sort(x)")) == :skip
      assert Math.mutate(parse("Math.sin(x)")) == :skip
    end

    test "skips non-call nodes" do
      assert Math.mutate(parse("x + y")) == :skip
      assert Math.mutate(parse("foo(x)")) == :skip
      assert Math.mutate(42) == :skip
    end

    test "name" do
      assert Math.name() == :math
    end
  end

  describe "Integer" do
    test "mod ↔ floor_div swap (arity-blind rename, args preserved)" do
      assert render(Integer.mutate(parse("Integer.mod(a, b)"))) == ["Integer.floor_div(a, b)"]
      assert render(Integer.mutate(parse("Integer.floor_div(a, b)"))) == ["Integer.mod(a, b)"]
    end

    test "is_even ↔ is_odd swap (the guard-safe parity predicates)" do
      assert render(Integer.mutate(parse("Integer.is_even(n)"))) == ["Integer.is_odd(n)"]
      assert render(Integer.mutate(parse("Integer.is_odd(n)"))) == ["Integer.is_even(n)"]
    end

    test "skips unrelated Integer calls and other modules" do
      assert Integer.mutate(parse("Integer.gcd(a, b)")) == :skip
      assert Integer.mutate(parse("Integer.parse(s)")) == :skip
      assert Integer.mutate(parse("Enum.mod(a, b)")) == :skip
      assert Integer.mutate(parse(":math.sin(x)")) == :skip
    end

    test "skips non-call nodes" do
      assert Integer.mutate(parse("a + b")) == :skip
      assert Integer.mutate(parse("n")) == :skip
      assert Integer.mutate(:atom) == :skip
    end

    test "name" do
      assert Integer.name() == :integer
    end
  end

  describe "StringLiteral" do
    test "mutates a non-empty string into both the empty string and the sentinel" do
      assert render(StringLiteral.mutate(parse(~s("hello")))) == [~s(""), ~s("mutare")]
    end

    test "drops the replacement that already equals the original" do
      # "" can't become "" again; "mutare" can't become "mutare" again
      assert render(StringLiteral.mutate(parse(~s("")))) == [~s("mutare")]
      assert render(StringLiteral.mutate(parse(~s("mutare")))) == [~s("")]
    end

    test "skips non-string literals" do
      assert StringLiteral.mutate(parse("1")) == :skip
      assert StringLiteral.mutate(parse(":atom")) == :skip
    end

    test "name" do
      assert StringLiteral.name() == :string
    end
  end

  describe "FloatLiteral" do
    test "mutates a float to x+1.0, x-1.0 and 0.0, deduped and never itself" do
      assert render(FloatLiteral.mutate(parse("1.5"))) == ["2.5", "0.5", "0.0"]
      assert render(FloatLiteral.mutate(parse("0.0"))) == ["1.0", "-1.0"]
    end

    test "skips integers" do
      assert FloatLiteral.mutate(parse("1")) == :skip
    end

    test "name" do
      assert FloatLiteral.name() == :float
    end
  end

  describe "AtomLiteral" do
    test "mutates a literal atom into the sentinel atom" do
      assert render(AtomLiteral.mutate(parse(":ok"))) == [":mutare"]
      assert render(AtomLiteral.mutate(parse(":some_status"))) == [":mutare"]
    end

    test "drops the replacement that already equals the sentinel" do
      assert AtomLiteral.mutate(parse(":mutare")) == :skip
    end

    test "skips true/false/nil (handled by Literal / Conditional, or absence)" do
      assert AtomLiteral.mutate(parse("true")) == :skip
      assert AtomLiteral.mutate(parse("false")) == :skip
      assert AtomLiteral.mutate(parse("nil")) == :skip
    end

    test "skips non-atom literals and bare atoms (function names, etc.)" do
      assert AtomLiteral.mutate(parse("1")) == :skip
      assert AtomLiteral.mutate(parse(~s("str"))) == :skip
      # A bare (un-`__block__`-wrapped) atom is never a literal node the analyzer offers.
      assert AtomLiteral.mutate(:upcase) == :skip
    end

    test "name" do
      assert AtomLiteral.name() == :atom
    end
  end

  describe "CharlistLiteral" do
    test "mutates a ~c sigil into the empty charlist and the sentinel" do
      assert render(CharlistLiteral.mutate(parse(~S|~c"abc"|))) == [~S|~c""|, ~S|~c"mutare"|]
    end

    test "drops the replacement that already equals the original" do
      assert render(CharlistLiteral.mutate(parse(~S|~c""|))) == [~S|~c"mutare"|]
      assert render(CharlistLiteral.mutate(parse(~S|~c"mutare"|))) == [~S|~c""|]
    end

    test "leaves the legacy '...' form alone (owned by List, which empties it)" do
      assert CharlistLiteral.mutate(parse("'abc'")) == :skip
    end

    test "skips strings and other literals" do
      assert CharlistLiteral.mutate(parse(~s("abc"))) == :skip
      assert CharlistLiteral.mutate(parse(":abc")) == :skip
    end

    test "name" do
      assert CharlistLiteral.name() == :charlist
    end
  end

  describe "WordListLiteral" do
    test "mutates a ~w sigil into the empty word list and the sentinel" do
      assert render(WordListLiteral.mutate(parse("~w(foo bar baz)"))) == ["~w()", "~w(mutare)"]
    end

    test "mutates an uppercase ~W sigil the same way" do
      assert render(WordListLiteral.mutate(parse("~W(foo bar)"))) == ["~W()", "~W(mutare)"]
    end

    test "preserves the modifier so the element type is unchanged" do
      assert render(WordListLiteral.mutate(parse("~w(foo bar)a"))) == ["~w()a", "~w(mutare)a"]
      assert render(WordListLiteral.mutate(parse("~w(foo bar)c"))) == ["~w()c", "~w(mutare)c"]
    end

    test "drops the replacement that already equals the original (by words produced)" do
      assert render(WordListLiteral.mutate(parse("~w()"))) == ["~w(mutare)"]
      assert render(WordListLiteral.mutate(parse("~w(mutare)"))) == ["~w()"]
      # whitespace-only already produces [], so the empty mutant is not re-emitted
      assert render(WordListLiteral.mutate(parse("~w(   )"))) == ["~w(mutare)"]
    end

    test "skips an interpolated ~w (parsed as multiple <<>> parts, not a static binary)" do
      assert WordListLiteral.mutate(parse(~S|~w(foo #{x} bar)|)) == :skip
    end

    test "skips other sigils and list literals (owned elsewhere)" do
      assert WordListLiteral.mutate(parse(~S|~c"abc"|)) == :skip
      assert WordListLiteral.mutate(parse("[1, 2, 3]")) == :skip
    end

    test "name" do
      assert WordListLiteral.name() == :word_list
    end
  end

  describe "MapLiteral" do
    test "collapses a non-empty map literal to %{}" do
      assert render(MapLiteral.mutate(parse("%{a: 1, b: 2}"))) == ["%{}"]
      assert render(MapLiteral.mutate(parse("%{1 => 2}"))) == ["%{}"]
    end

    test "skips the empty map and a map update" do
      assert MapLiteral.mutate(parse("%{}")) == :skip
      assert MapLiteral.mutate(parse("%{m | a: 1}")) == :skip
    end

    test "name" do
      assert MapLiteral.name() == :map
    end
  end

  describe "TupleLiteral" do
    test "collapses a non-empty tuple literal to {} (both 2- and 3+-arity)" do
      assert render(TupleLiteral.mutate(parse("{1, 2}"))) == ["{}"]
      assert render(TupleLiteral.mutate(parse("{1, 2, 3}"))) == ["{}"]
      assert render(TupleLiteral.mutate(parse("{:ok}"))) == ["{}"]
    end

    test "skips the empty tuple" do
      assert TupleLiteral.mutate(parse("{}")) == :skip
    end

    test "name" do
      assert TupleLiteral.name() == :tuple
    end
  end

  describe "BitstringLiteral" do
    test "collapses a non-empty bitstring literal to <<>>" do
      assert render(BitstringLiteral.mutate(parse("<<1, 2, 3>>"))) == ["<<>>"]
      assert render(BitstringLiteral.mutate(parse(~S|<<"abc">>|))) == ["<<>>"]
    end

    test "skips the empty bitstring" do
      assert BitstringLiteral.mutate(parse("<<>>")) == :skip
    end

    test "skips an interpolated string (a `<<>>` written as a string)" do
      # `"a#{x}b"` parses as a `<<>>` carrying a delimiter — StringLiteral's domain.
      assert BitstringLiteral.mutate(parse(~S|"a#{x}b"|)) == :skip
      assert BitstringLiteral.mutate(parse(~S|"#{x}"|)) == :skip
    end

    test "skips a plain string and other literals" do
      assert BitstringLiteral.mutate(parse(~s("abc"))) == :skip
      assert BitstringLiteral.mutate(parse("[1, 2]")) == :skip
    end

    test "name" do
      assert BitstringLiteral.name() == :bitstring
    end
  end

  describe "RegexLiteral" do
    test "mutates a ~r pattern into the empty pattern and the sentinel" do
      assert render(RegexLiteral.mutate(parse(~S|~r/foo/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "preserves modifier flags on the whole-pattern replacements" do
      assert render(RegexLiteral.mutate(parse(~S|~r/foo/i|))) ==
               [~S|~r//i|, ~S|~r/mutare/i|, ~S|~r/foo/|]
    end

    test "drops the replacement that already equals the original" do
      assert render(RegexLiteral.mutate(parse(~S|~r//|))) == [~S|~r/mutare/|]
    end

    test "drops a leading ^ anchor" do
      assert ~S|~r/abc/| in render(RegexLiteral.mutate(parse(~S|~r/^abc/|)))
    end

    test "drops an unescaped trailing $ anchor" do
      assert ~S|~r/abc/| in render(RegexLiteral.mutate(parse(~S|~r/abc$/|)))
    end

    test "drops each anchor of ^abc$ independently" do
      mutants = render(RegexLiteral.mutate(parse(~S|~r/^abc$/|)))
      assert ~S|~r/abc$/| in mutants
      assert ~S|~r/^abc/| in mutants
    end

    test "leaves an escaped trailing $ alone" do
      refute ~S|~r/abc\$/| in render(RegexLiteral.mutate(parse(~S|~r/abc\$/|)))
      assert render(RegexLiteral.mutate(parse(~S|~r/abc\$/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "complements a \\d/\\w/\\s shorthand and swaps each quantifier, in source order" do
      # `\d` → `\D` and `+` → `*` interleave left-to-right across the two stages.
      assert render(RegexLiteral.mutate(parse(~S|~r/\d+\.\d+/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/\D+\.\d+/|,
                 ~S|~r/\d*\.\d+/|,
                 ~S|~r/\d+\.\D+/|,
                 ~S|~r/\d+\.\d*/|
               ]

      assert ~S|~r/\d/| in render(RegexLiteral.mutate(parse(~S|~r/\D/|)))
    end

    test "complements a \\b word boundary only outside a character class" do
      assert ~S|~r/\B/| in render(RegexLiteral.mutate(parse(~S|~r/\b/|)))
      # inside a class \b is a backspace — only the class negation is offered
      assert render(RegexLiteral.mutate(parse(~S|~r/[\b]/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/[^\b]/|]
    end

    test "does not treat an escaped backslash as a shorthand" do
      assert render(RegexLiteral.mutate(parse(~S|~r/\\d/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "toggles a character class between matching and negated" do
      assert ~S|~r/[^abc]/| in render(RegexLiteral.mutate(parse(~S|~r/[abc]/|)))
      assert ~S|~r/[abc]/| in render(RegexLiteral.mutate(parse(~S|~r/[^abc]/|)))
    end

    test "negates a class with a literal leading ] correctly" do
      assert ~S|~r/[^]a]/| in render(RegexLiteral.mutate(parse(~S|~r/[]a]/|)))
    end

    test "offers both negation and shorthand swaps inside one class" do
      mutants = render(RegexLiteral.mutate(parse(~S|~r/[\d]/|)))
      assert ~S|~r/[^\d]/| in mutants
      assert ~S|~r/[\D]/| in mutants
    end

    test "drops a leading \\A and a trailing \\z/\\Z anchor" do
      assert ~S|~r/start/| in render(RegexLiteral.mutate(parse(~S|~r/\Astart/|)))
      assert ~S|~r/end/| in render(RegexLiteral.mutate(parse(~S|~r/end\z/|)))
      assert ~S|~r/end/| in render(RegexLiteral.mutate(parse(~S|~r/end\Z/|)))
      # an escaped backslash before z is not an anchor
      assert render(RegexLiteral.mutate(parse(~S|~r/end\\z/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "swaps a + quantifier to * and back" do
      assert ~S|~r/\d*/| in render(RegexLiteral.mutate(parse(~S|~r/\d+/|)))
      assert ~S|~r/a+/| in render(RegexLiteral.mutate(parse(~S|~r/a*/|)))
    end

    test "leaves a lazy/possessive suffix and a quantifier inside a class alone" do
      # the `+` swaps to `*`; the trailing lazy `?` is a suffix, not a fresh quantifier
      assert render(RegexLiteral.mutate(parse(~S|~r/a+?/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a*?/|]

      # `*`/`+` inside a class are literal — only the class negation is offered
      assert render(RegexLiteral.mutate(parse(~S|~r/[*+]/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/[^*+]/|]
    end

    test "turns an optional ? mandatory (drop it, and raise it to +)" do
      mutants = render(RegexLiteral.mutate(parse(~S|~r/colou?r/|)))
      assert ~S|~r/colour/| in mutants
      assert ~S|~r/colou+r/| in mutants
    end

    test "does not treat a ? group marker as an optional quantifier" do
      # the `?` in `(?:…)` is a group marker, not a quantifier — nothing to mutate here
      assert render(RegexLiteral.mutate(parse(~S|~r/(?:ab)/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "nudges a bounded quantifier's counts by one, staying in range" do
      assert render(RegexLiteral.mutate(parse(~S|~r/a{3}/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a{2}/|, ~S|~r/a{4}/|]

      assert render(RegexLiteral.mutate(parse(~S|~r/a{8,}/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a{7,}/|, ~S|~r/a{9,}/|]

      assert render(RegexLiteral.mutate(parse(~S|~r/a{2,4}/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/a{1,4}/|,
                 ~S|~r/a{3,4}/|,
                 ~S|~r/a{2,3}/|,
                 ~S|~r/a{2,5}/|
               ]

      # a lower bound never goes below zero
      assert render(RegexLiteral.mutate(parse(~S|~r/a{0,2}/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a{1,2}/|, ~S|~r/a{0,1}/|, ~S|~r/a{0,3}/|]

      # Boundary cases where a ±1 neighbour lands *exactly* on the clamp edge — the
      # only inputs that pin the inclusive `>= 0` / `>= n` / `<= m` filters (a
      # strict `>`/`<` would drop the edge value, an unconditional filter would
      # keep an out-of-range one).
      #   `a{1}` (exact): the lower neighbour is exactly 0 — kept (≥ 0), so `a{0}`.
      assert render(RegexLiteral.mutate(parse(~S|~r/a{1}/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a{0}/|, ~S|~r/a{2}/|]

      #   `a{0}` (exact 0): the lower neighbour −1 is dropped (< 0), only `a{1}`.
      assert render(RegexLiteral.mutate(parse(~S|~r/a{0}/|))) ==
               [~S|~r//|, ~S|~r/mutare/|, ~S|~r/a{1}/|]

      #   `a{1,4}` (range): lower neighbour 0 kept (≥ 0 and ≤ m), so `a{0,4}`.
      assert render(RegexLiteral.mutate(parse(~S|~r/a{1,4}/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/a{0,4}/|,
                 ~S|~r/a{2,4}/|,
                 ~S|~r/a{1,3}/|,
                 ~S|~r/a{1,5}/|
               ]

      #   `a{2,3}` (range): the upper's lower neighbour is exactly n (2) — kept
      #   (≥ n), so `a{2,2}`; the lower's upper neighbour 3 is ≤ m, so `a{3,3}`.
      assert render(RegexLiteral.mutate(parse(~S|~r/a{2,3}/|))) ==
               [
                 ~S|~r//|,
                 ~S|~r/mutare/|,
                 ~S|~r/a{1,3}/|,
                 ~S|~r/a{3,3}/|,
                 ~S|~r/a{2,2}/|,
                 ~S|~r/a{2,4}/|
               ]
    end

    test "leaves a non-quantifier brace alone" do
      assert render(RegexLiteral.mutate(parse(~S|~r/a{b}/|))) == [~S|~r//|, ~S|~r/mutare/|]
    end

    test "drops one branch of a top-level alternation" do
      mutants = render(RegexLiteral.mutate(parse(~S"~r/a|b|c/")))
      assert ~S"~r/b|c/" in mutants
      assert ~S"~r/a|c/" in mutants
      assert ~S"~r/a|b/" in mutants
    end

    test "drops one branch of an alternation inside a capturing group" do
      mutants = render(RegexLiteral.mutate(parse(~S"~r/^(GET|POST)$/")))
      assert ~S"~r/^(POST)$/" in mutants
      assert ~S"~r/^(GET)$/" in mutants
    end

    test "does not touch alternation inside a non-capturing group" do
      refute ~S"~r/(?:a)/" in render(RegexLiteral.mutate(parse(~S"~r/(?:a|b)/")))
      refute ~S"~r/(?:b)/" in render(RegexLiteral.mutate(parse(~S"~r/(?:a|b)/")))
    end

    test "does not treat a pipe inside a character class as alternation" do
      # `|` is a literal inside `[…]`, so only the class negation is offered
      assert render(RegexLiteral.mutate(parse(~S"~r/[a|b]/"))) ==
               [~S"~r//", ~S"~r/mutare/", ~S"~r/[^a|b]/"]
    end

    test "drops each present modifier flag one at a time" do
      assert render(RegexLiteral.mutate(parse(~S|~r/foo/uis|))) ==
               [~S|~r//uis|, ~S|~r/mutare/uis|, ~S|~r/foo/is|, ~S|~r/foo/us|, ~S|~r/foo/ui|]
    end

    test "skips an interpolated pattern" do
      assert RegexLiteral.mutate(parse(~S|~r/a#{b}c/|)) == :skip
    end

    test "name" do
      assert RegexLiteral.name() == :regex
    end
  end

  describe "DateTimeLiteral" do
    test "shifts each calendar sigil by one unit, staying valid" do
      assert render(DateTimeLiteral.mutate(parse("~D[2020-01-31]"))) == ["~D[2020-02-01]"]
      assert render(DateTimeLiteral.mutate(parse("~T[23:59:59]"))) == ["~T[00:00:00]"]

      assert render(DateTimeLiteral.mutate(parse("~N[2020-01-01 00:00:00]"))) ==
               ["~N[2020-01-02T00:00:00]"]

      assert render(DateTimeLiteral.mutate(parse("~U[2020-01-01 00:00:00Z]"))) ==
               ["~U[2020-01-02T00:00:00Z]"]
    end

    test "every shifted result is a real, re-parseable sigil" do
      for src <- [
            "~D[2020-12-31]",
            "~T[12:00:00]",
            "~N[2020-02-28 23:59:59]",
            "~U[1999-12-31 23:59:59Z]"
          ] do
        [mutated] = DateTimeLiteral.mutate(parse(src))
        assert {:ok, _} = Code.string_to_quoted(Sourceror.to_string(mutated))
      end
    end

    test "skips non-calendar sigils and other literals" do
      assert DateTimeLiteral.mutate(parse(~S|~r/foo/|)) == :skip
      assert DateTimeLiteral.mutate(parse("1")) == :skip
    end

    test "name" do
      assert DateTimeLiteral.name() == :datetime
    end
  end

  describe "AliasLiteral" do
    test "replaces a fully-literal alias with the sentinel alias" do
      assert render(AliasLiteral.mutate(parse("Foo"))) == ["Mutare.Mutant"]
      assert render(AliasLiteral.mutate(parse("Foo.Bar.Baz"))) == ["Mutare.Mutant"]
    end

    test "drops the replacement that already equals the sentinel" do
      assert AliasLiteral.mutate(parse("Mutare.Mutant")) == :skip
    end

    test "skips a dynamic alias (a segment that is not an atom)" do
      # `__MODULE__.Sub` — the first segment is `{:__MODULE__, _, nil}`, not an atom.
      assert AliasLiteral.mutate(parse("__MODULE__.Sub")) == :skip
    end

    test "skips non-alias nodes" do
      assert AliasLiteral.mutate(parse(":foo")) == :skip
      assert AliasLiteral.mutate(parse("foo")) == :skip
      assert AliasLiteral.mutate(parse("1")) == :skip
    end

    test "name" do
      assert AliasLiteral.name() == :alias
    end
  end

  defp parse(source), do: Sourceror.parse_string!(source)
  defp render(nodes), do: Enum.map(nodes, &Sourceror.to_string/1)

  # CollectionArity's mutate/2 receives %{pipe_mode: :piped | :unpiped}; effective arity =
  # visible args + (one when :piped). The boolean `piped?` is this test's shorthand; `context/1`
  # adapts it to the production context shape.
  defp arity(src, piped?),
    do: render(Mutare.Mutators.CollectionArity.mutate(parse(src), context(piped?)))

  defp removal(src, piped?),
    do: render(Mutare.Mutators.CallRemoval.mutate(parse(src), context(piped?)))

  defp dropd(src, piped?),
    do: render(Mutare.Mutators.DefaultDrop.mutate(parse(src), context(piped?)))

  defp mode(src, piped?),
    do: render(Mutare.Mutators.ModeSwap.mutate(parse(src), context(piped?)))

  defp numeric(src, piped?),
    do: render(Mutare.Mutators.Numeric.mutate(parse(src), context(piped?)))

  defp context(true), do: %{pipe_mode: :piped}
  defp context(false), do: %{pipe_mode: :unpiped}
end
