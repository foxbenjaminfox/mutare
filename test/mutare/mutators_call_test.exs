defmodule Mutare.MutatorsCallTest do
  # Unit tests of the call-matching families' `mutate/1` / `mutate/2`: the rename and
  # arity-changing swap tables (resolved-call families). Resolution routing (alias/import/
  # Erlang-atom) and pipe-awareness live in transform_test.exs; this file probes the swap
  # logic directly on parsed call nodes.
  use ExUnit.Case, async: true

  alias Mutare.Mutators.{
    CallRemoval,
    Collection,
    CollectionArity,
    DefaultDrop,
    IntegerCall,
    KeywordDelete,
    Math,
    MapKeyword,
    ModeSwap,
    Numeric,
    PeriodBoundary,
    StringByte,
    StringCall,
    TemporalOrder
  }

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

    test "swaps Map, Keyword, and MapSet complements, keeping arguments" do
      assert render(Collection.mutate(parse("Map.filter(m, f)"))) == ["Map.reject(m, f)"]
      assert render(Collection.mutate(parse("Map.reject(m, f)"))) == ["Map.filter(m, f)"]
      assert render(Collection.mutate(parse("Map.take(m, keys)"))) == ["Map.drop(m, keys)"]
      assert render(Collection.mutate(parse("Map.drop(m, keys)"))) == ["Map.take(m, keys)"]

      assert render(Collection.mutate(parse("Keyword.filter(kw, f)"))) ==
               ["Keyword.reject(kw, f)"]

      assert render(Collection.mutate(parse("Keyword.reject(kw, f)"))) ==
               ["Keyword.filter(kw, f)"]

      assert render(Collection.mutate(parse("Keyword.take(kw, keys)"))) ==
               ["Keyword.drop(kw, keys)"]

      assert render(Collection.mutate(parse("Keyword.drop(kw, keys)"))) ==
               ["Keyword.take(kw, keys)"]

      assert render(Collection.mutate(parse("MapSet.filter(set, f)"))) ==
               ["MapSet.reject(set, f)"]

      assert render(Collection.mutate(parse("MapSet.reject(set, f)"))) ==
               ["MapSet.filter(set, f)"]
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

  describe "PeriodBoundary" do
    test "swaps a period boundary for its opposite end, keeping arguments" do
      assert render(PeriodBoundary.mutate(parse("Date.beginning_of_month(d)"))) ==
               ["Date.end_of_month(d)"]

      assert render(PeriodBoundary.mutate(parse("Date.end_of_month(d)"))) ==
               ["Date.beginning_of_month(d)"]

      assert render(PeriodBoundary.mutate(parse("Date.beginning_of_week(d)"))) ==
               ["Date.end_of_week(d)"]

      assert render(PeriodBoundary.mutate(parse("Date.end_of_week(d)"))) ==
               ["Date.beginning_of_week(d)"]

      assert render(PeriodBoundary.mutate(parse("NaiveDateTime.beginning_of_day(n)"))) ==
               ["NaiveDateTime.end_of_day(n)"]

      assert render(PeriodBoundary.mutate(parse("NaiveDateTime.end_of_day(n)"))) ==
               ["NaiveDateTime.beginning_of_day(n)"]
    end

    test "is arity-blind — the week pair carries its starting_on weekday along" do
      assert render(PeriodBoundary.mutate(parse("Date.beginning_of_week(d, :sunday)"))) ==
               ["Date.end_of_week(d, :sunday)"]

      assert render(PeriodBoundary.mutate(parse("Date.end_of_week(d, :sunday)"))) ==
               ["Date.beginning_of_week(d, :sunday)"]
    end

    test "skips functions and modules it does not own" do
      # DateTime has no beginning_of_day/end_of_day; Time has no period boundaries.
      assert PeriodBoundary.mutate(parse("DateTime.beginning_of_day(dt)")) == :skip
      assert PeriodBoundary.mutate(parse("Date.add(d, 1)")) == :skip
      assert PeriodBoundary.mutate(parse("Other.beginning_of_month(d)")) == :skip
      assert PeriodBoundary.mutate(parse("local(d)")) == :skip
    end

    test "name" do
      assert PeriodBoundary.name() == :period_boundary
    end
  end

  describe "TemporalOrder" do
    test "swaps temporal before?/after? calls, keeping arguments" do
      assert render(TemporalOrder.mutate(parse("Date.before?(a, b)"))) ==
               ["Date.after?(a, b)"]

      assert render(TemporalOrder.mutate(parse("Date.after?(a, b)"))) ==
               ["Date.before?(a, b)"]

      assert render(TemporalOrder.mutate(parse("Time.before?(a, b)"))) ==
               ["Time.after?(a, b)"]

      assert render(TemporalOrder.mutate(parse("DateTime.before?(a, b)"))) ==
               ["DateTime.after?(a, b)"]

      assert render(TemporalOrder.mutate(parse("NaiveDateTime.after?(a, b)"))) ==
               ["NaiveDateTime.before?(a, b)"]
    end

    test "skips unrelated modules and functions" do
      assert TemporalOrder.mutate(parse("Date.compare(a, b)")) == :skip
      assert TemporalOrder.mutate(parse("Other.before?(a, b)")) == :skip
    end

    test "name" do
      assert TemporalOrder.name() == :temporal_order
    end
  end

  describe "CollectionArity" do
    test "does not implement mutate/1 (pipe-aware logic lives in mutate/2)" do
      refute function_exported?(CollectionArity, :mutate, 1)
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

    test "substitutes String.equivalent?(a, b) with Elixir.Kernel.== (dropping normalization)" do
      # Absolute-qualified (not a bare `a == b`) so neither a local/imported `==` nor a
      # rebound `Kernel` alias can shadow it.
      assert render(StringCall.mutate(parse("String.equivalent?(a, b)"))) ==
               ["Elixir.Kernel.==(a, b)"]

      assert render(StringCall.mutate(parse(~s|String.equivalent?(x, "foo")|))) == [
               ~s|Elixir.Kernel.==(x, "foo")|
             ]

      # a 1-arg call is only reachable as a `|>` stage — becomes `a |> Elixir.Kernel.==(b)`
      assert render(StringCall.mutate(parse("String.equivalent?(b)"))) == ["Elixir.Kernel.==(b)"]
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

  describe "StringByte" do
    test "narrows String.length to Elixir.Kernel.byte_size (graphemes -> bytes)" do
      assert render(StringByte.mutate(parse("String.length(s)"))) == [
               "Elixir.Kernel.byte_size(s)"
             ]

      # piped: the LHS-less stage rewrites to the LHS-less Elixir.Kernel.byte_size
      assert render(StringByte.mutate(parse("String.length()"))) == ["Elixir.Kernel.byte_size()"]
    end

    test "is one-way: never broadens byte_size back to String.length" do
      assert StringByte.mutate(parse("byte_size(s)")) == :skip
      assert StringByte.mutate(parse("Kernel.byte_size(s)")) == :skip
      assert StringByte.mutate(parse("Elixir.Kernel.byte_size(s)")) == :skip
    end

    test "skips other String calls and other modules" do
      assert StringByte.mutate(parse("String.first(s)")) == :skip
      assert StringByte.mutate(parse("String.at(s, i)")) == :skip
      assert StringByte.mutate(parse("String.slice(s, 1, 3)")) == :skip
      assert StringByte.mutate(parse("Map.get(m, k)")) == :skip
      assert StringByte.mutate(parse("length(xs)")) == :skip
    end

    test "name" do
      assert StringByte.name() == :string_byte
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

  describe "KeywordDelete" do
    test "does not implement mutate/1 (arity-gated logic lives in mutate/2)" do
      refute function_exported?(KeywordDelete, :mutate, 1)
    end

    test "swaps delete ↔ delete_first at /2, keeping arguments" do
      assert kwdel("Keyword.delete(kw, k)", false) == ["Keyword.delete_first(kw, k)"]
      assert kwdel("Keyword.delete_first(kw, k)", false) == ["Keyword.delete(kw, k)"]
    end

    test "leaves the deprecated delete/3 alone (delete_first has no /3 twin)" do
      assert KeywordDelete.mutate(parse("Keyword.delete(kw, k, v)"), %{pipe_mode: :unpiped}) ==
               :skip
    end

    test "piped: effective arity is +1, so a /2 reaches us as one visible arg" do
      # `kw |> Keyword.delete(k)` — effective arity 2, swapped, keeping the stage shape.
      assert kwdel("Keyword.delete(k)", true) == ["Keyword.delete_first(k)"]
      assert kwdel("Keyword.delete_first(k)", true) == ["Keyword.delete(k)"]
      # `kw |> Keyword.delete(k, v)` — effective arity 3, the deprecated form, left alone.
      assert KeywordDelete.mutate(parse("Keyword.delete(k, v)"), %{pipe_mode: :piped}) == :skip
    end

    test "skips Map (no duplicate-key distinction) and unrelated calls" do
      # Map keys are unique — there is no Map.delete_first.
      assert KeywordDelete.mutate(parse("Map.delete(m, k)"), %{pipe_mode: :unpiped}) == :skip
      assert KeywordDelete.mutate(parse("Keyword.drop(kw, ks)"), %{pipe_mode: :unpiped}) == :skip
      assert KeywordDelete.mutate(parse("Other.delete(kw, k)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "name" do
      assert KeywordDelete.name() == :keyword_delete
    end
  end

  describe "CallRemoval" do
    test "does not implement mutate/1 (pipe-aware logic lives in mutate/2)" do
      refute function_exported?(CallRemoval, :mutate, 1)
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

    test "removes Map/Keyword/List key & element strippers, returning the collection" do
      # Map/Keyword strippers — same-typed collection back, with the keys un-removed
      # (delete/drop) or un-projected (take returns a subset; removal returns the whole).
      assert removal("Map.delete(m, k)", false) == ["m"]
      assert removal("Map.drop(m, ks)", false) == ["m"]
      assert removal("Map.take(m, ks)", false) == ["m"]
      assert removal("Keyword.delete(kw, k)", false) == ["kw"]
      # Keyword.delete/3 (the deprecated key+value form) is removed arity-blind too.
      assert removal("Keyword.delete(kw, k, v)", false) == ["kw"]
      assert removal("Keyword.drop(kw, ks)", false) == ["kw"]
      assert removal("Keyword.take(kw, ks)", false) == ["kw"]
      # List element strippers — by value, index, or tuple-key.
      assert removal("List.delete(xs, x)", false) == ["xs"]
      assert removal("List.delete_at(xs, 2)", false) == ["xs"]
      assert removal("List.keydelete(xs, :k, 0)", false) == ["xs"]
      # Piped: a no-op stage the pipe feeds (the collection is the |> LHS).
      assert removal("Map.delete(k)", true) == ["Elixir.Function.identity()"]
      assert removal("List.delete_at(2)", true) == ["Elixir.Function.identity()"]
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
      assert removal(":string.slice(1, 3)", true) == ["Elixir.Function.identity()"]
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

    test "piped: replaces the stage with Elixir.Function.identity() (a no-op the pipe feeds)" do
      # `x |> Enum.sort(:desc)` reaches us as a 1-arg node; the piped flag means the
      # input is the |> LHS, so we must NOT return the comparator — identity instead.
      assert removal("Enum.sort()", true) == ["Elixir.Function.identity()"]
      assert removal("Enum.sort(:desc)", true) == ["Elixir.Function.identity()"]
      assert removal("String.trim()", true) == ["Elixir.Function.identity()"]
      assert removal("Enum.uniq()", true) == ["Elixir.Function.identity()"]
      assert removal("Enum.intersperse(0)", true) == ["Elixir.Function.identity()"]
      assert removal("List.flatten()", true) == ["Elixir.Function.identity()"]
      # `s |> String.normalize(:nfc)` — the form is the LHS-less visible arg, so we
      # must return identity, never the `:nfc` atom.
      assert removal("String.normalize(:nfc)", true) == ["Elixir.Function.identity()"]
      assert removal("String.pad_leading(5)", true) == ["Elixir.Function.identity()"]
      assert removal("String.slice(1, 3)", true) == ["Elixir.Function.identity()"]
      assert removal("URI.encode_www_form()", true) == ["Elixir.Function.identity()"]
      assert removal("NaiveDateTime.beginning_of_day()", true) == ["Elixir.Function.identity()"]
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
      assert removal("abs()", true) == ["Elixir.Function.identity()"]
    end

    test "qualified Kernel.abs is removed arity-blind (the prefix proves it)" do
      assert removal("Kernel.abs(x)", false) == ["x"]
      assert removal("Kernel.abs()", true) == ["Elixir.Function.identity()"]
    end

    test "the Kernel binary slicers are removed, returning the whole binary" do
      # Bare — keyed on effective arity (binary_slice/2,/3 and binary_part/3 exist).
      assert removal("binary_slice(b, 0, 5)", false) == ["b"]
      assert removal("binary_slice(b, 0..4)", false) == ["b"]
      assert removal("binary_part(b, 0, 5)", false) == ["b"]
      # Piped — the LHS-less stage becomes a no-op the pipe feeds.
      assert removal("binary_slice(0..4)", true) == ["Elixir.Function.identity()"]
      assert removal("binary_part(0, 5)", true) == ["Elixir.Function.identity()"]
      # Qualified Kernel — arity-blind (the prefix proves the function).
      assert removal("Kernel.binary_slice(b, r)", false) == ["b"]
      assert removal("Kernel.binary_part(b, 0, 5)", false) == ["b"]
    end

    test "binary_part/2 (only :erlang.binary_part/2) is removed via its Erlang form" do
      # `binary_part/2` is not a Kernel function — its sole incarnation is
      # `:erlang.binary_part(bin, {start, len})`. Removed arity-blind like :string.
      assert removal(":erlang.binary_part(b, {0, 5})", false) == ["b"]
      assert removal(":erlang.binary_part(b, 0, 5)", false) == ["b"]
      assert removal(":erlang.binary_part({0, 5})", true) == ["Elixir.Function.identity()"]
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

    test "abs: does not implement mutate/1 (bare Kernel, pipe-aware logic in mutate/2)" do
      refute function_exported?(CallRemoval, :mutate, 1)
    end

    test "name" do
      assert CallRemoval.name() == :call_removal
    end
  end

  describe "DefaultDrop" do
    test "does not implement mutate/1 (pipe-aware logic lives in mutate/2)" do
      refute function_exported?(DefaultDrop, :mutate, 1)
    end

    test "non-piped: drops a non-nil trailing default, reverting to the /2 lookup" do
      assert dropd("Map.get(m, k, :default)", false) == ["Map.get(m, k)"]
      assert dropd("Keyword.get(kw, k, 0)", false) == ["Keyword.get(kw, k)"]
      assert dropd("Access.get(m, k, :default)", false) == ["Access.get(m, k)"]
      assert dropd("Access.key(k, :default)", false) == ["Access.key(k)"]
      assert dropd("Map.pop(m, k, :d)", false) == ["Map.pop(m, k)"]
      assert dropd("Keyword.pop_first(kw, k, :d)", false) == ["Keyword.pop_first(kw, k)"]
      assert dropd("Enum.at(xs, i, :none)", false) == ["Enum.at(xs, i)"]
      assert dropd("List.pop_at(xs, i, :empty)", false) == ["List.pop_at(xs, i)"]
      assert dropd("List.keyfind(xs, k, 0, :none)", false) == ["List.keyfind(xs, k, 0)"]
      assert dropd("List.flatten(xs, [:tail])", false) == ["List.flatten(xs)"]
      assert dropd("List.first(xs, :empty)", false) == ["List.first(xs)"]
      assert dropd("List.last(xs, :empty)", false) == ["List.last(xs)"]
    end

    test "a literal nil default is skipped (equivalent — nil is the implicit default)" do
      assert DefaultDrop.mutate(parse("Map.get(m, k, nil)"), %{pipe_mode: :unpiped}) == :skip
      assert DefaultDrop.mutate(parse("Keyword.get(kw, k, nil)"), %{pipe_mode: :unpiped}) == :skip

      assert DefaultDrop.mutate(parse("Access.get(m, k, nil)"), %{pipe_mode: :unpiped}) ==
               :skip

      assert DefaultDrop.mutate(parse("Access.key(k, nil)"), %{pipe_mode: :unpiped}) == :skip

      assert DefaultDrop.mutate(parse("Keyword.pop_first(kw, k, nil)"), %{pipe_mode: :unpiped}) ==
               :skip

      assert DefaultDrop.mutate(parse("List.pop_at(xs, i, nil)"), %{pipe_mode: :unpiped}) ==
               :skip

      assert DefaultDrop.mutate(parse("List.keyfind(xs, k, 0, nil)"), %{pipe_mode: :unpiped}) ==
               :skip

      assert DefaultDrop.mutate(parse("List.flatten(xs, [])"), %{pipe_mode: :unpiped}) ==
               :skip

      # but a non-nil falsy default (false, 0) is a real difference — still dropped.
      assert dropd("Map.get(m, k, false)", false) == ["Map.get(m, k)"]
      assert dropd("Map.get(m, k, 0)", false) == ["Map.get(m, k)"]
    end

    test "_lazy forms rename to the base lookup and drop the fallback fun" do
      assert dropd("Map.get_lazy(m, k, f)", false) == ["Map.get(m, k)"]
      assert dropd("Keyword.get_lazy(kw, k, f)", false) == ["Keyword.get(kw, k)"]
      assert dropd("Map.pop_lazy(m, k, f)", false) == ["Map.pop(m, k)"]
    end

    test "drops a rounding precision, reverting to the /1 form (implicit 0)" do
      assert dropd("Float.round(x, 2)", false) == ["Float.round(x)"]
      assert dropd("Float.ceil(x, 3)", false) == ["Float.ceil(x)"]
      assert dropd("Float.floor(x, 1)", false) == ["Float.floor(x)"]
      # An explicit precision of 0 is the implicit default — equivalent, skipped.
      assert DefaultDrop.mutate(parse("Float.round(x, 0)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "drops an integer base, reverting to base 10 (implicit 10)" do
      assert dropd("Integer.to_string(n, 16)", false) == ["Integer.to_string(n)"]
      assert dropd("Integer.to_charlist(n, 2)", false) == ["Integer.to_charlist(n)"]
      assert dropd("Integer.parse(s, 16)", false) == ["Integer.parse(s)"]
      assert dropd("Integer.digits(n, 2)", false) == ["Integer.digits(n)"]
      assert dropd("Integer.undigits(ds, 2)", false) == ["Integer.undigits(ds)"]
      # An explicit base of 10 is the implicit default — equivalent, skipped.
      assert DefaultDrop.mutate(parse("Integer.to_string(n, 10)"), %{pipe_mode: :unpiped}) ==
               :skip
    end

    test "drops the Enum.join separator (implicit \"\")" do
      assert dropd(~s|Enum.join(xs, ", ")|, false) == ["Enum.join(xs)"]
      # The empty-string separator is the implicit default — equivalent, skipped.
      assert DefaultDrop.mutate(parse(~s|Enum.join(xs, "")|), %{pipe_mode: :unpiped}) == :skip
    end

    test "drops the String pad fill (implicit \" \")" do
      assert dropd(~s|String.pad_leading(s, n, "*")|, false) == ["String.pad_leading(s, n)"]
      assert dropd(~s|String.pad_trailing(s, n, "0")|, false) == ["String.pad_trailing(s, n)"]
      # A single-space fill is the implicit default — equivalent, skipped.
      assert DefaultDrop.mutate(parse(~s|String.pad_leading(s, n, " ")|), %{pipe_mode: :unpiped}) ==
               :skip
    end

    test "drops the String trim char (no literal default — always drops, even \" \")" do
      assert dropd(~s|String.trim(s, "x")|, false) == ["String.trim(s)"]
      assert dropd(~s|String.trim_leading(s, "x")|, false) == ["String.trim_leading(s)"]
      assert dropd(~s|String.trim_trailing(s, "x")|, false) == ["String.trim_trailing(s)"]
      # `String.trim(s, " ")` trims only spaces, not all whitespace — NOT equivalent to
      # `String.trim(s)`, so it is still dropped (unlike the pad fill above).
      assert dropd(~s|String.trim(s, " ")|, false) == ["String.trim(s)"]
    end

    test "piped: refinement drops carry the +1 effective arity too" do
      assert dropd("Float.round(2)", true) == ["Float.round()"]
      assert dropd("Integer.to_string(16)", true) == ["Integer.to_string()"]
      assert dropd(~s|Enum.join(", ")|, true) == ["Enum.join()"]
      assert dropd(~s|String.pad_leading(n, "*")|, true) == ["String.pad_leading(n)"]
      # Piped equivalent default is still skipped.
      assert DefaultDrop.mutate(parse("Float.round(0)"), %{pipe_mode: :piped}) == :skip
    end

    test "the base /1 forms (nothing to drop) are not mutated" do
      assert DefaultDrop.mutate(parse("Float.round(x)"), %{pipe_mode: :unpiped}) == :skip
      assert DefaultDrop.mutate(parse("Integer.to_string(n)"), %{pipe_mode: :unpiped}) == :skip
      assert DefaultDrop.mutate(parse("Enum.join(xs)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "piped: effective arity is +1, so a /3 reaches us as 2 visible args" do
      # `m |> Map.get(k, :d)` — drop the trailing visible default, leaving the /2 stage.
      assert dropd("Map.get(k, :default)", true) == ["Map.get(k)"]
      assert dropd("Access.get(k, :default)", true) == ["Access.get(k)"]
      assert dropd("Access.key(:default)", true) == ["Access.key()"]
      assert dropd("Keyword.pop_first(k, :default)", true) == ["Keyword.pop_first(k)"]
      assert dropd("List.pop_at(i, :empty)", true) == ["List.pop_at(i)"]
      assert dropd("List.keyfind(k, 0, :none)", true) == ["List.keyfind(k, 0)"]
      assert dropd("List.flatten([:tail])", true) == ["List.flatten()"]
      assert dropd("List.first(:empty)", true) == ["List.first()"]
      assert dropd("Map.get_lazy(k, f)", true) == ["Map.get(k)"]
      # A piped nil default is still equivalent → skipped.
      assert DefaultDrop.mutate(parse("Map.get(k, nil)"), %{pipe_mode: :piped}) == :skip
      assert DefaultDrop.mutate(parse("List.pop_at(i, nil)"), %{pipe_mode: :piped}) == :skip
      assert DefaultDrop.mutate(parse("List.flatten([])"), %{pipe_mode: :piped}) == :skip
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
    test "does not implement mutate/1 (pipe-aware logic lives in mutate/2)" do
      refute function_exported?(ModeSwap, :mutate, 1)
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

    test "Unix-timestamp units (from_unix/to_unix) walk the System ladder" do
      assert mode("DateTime.from_unix(ts, :millisecond)", false) ==
               ["DateTime.from_unix(ts, :microsecond)", "DateTime.from_unix(ts, :second)"]

      # `:second` is the coarse endpoint of {nanosecond..second} — one neighbour.
      assert mode("DateTime.from_unix!(ts, :second)", false) ==
               ["DateTime.from_unix!(ts, :millisecond)"]

      assert mode("DateTime.to_unix(dt, :nanosecond)", false) ==
               ["DateTime.to_unix(dt, :microsecond)"]

      # :native maps to a concrete unit, like the System clock functions.
      assert mode("DateTime.to_unix(dt, :native)", false) == ["DateTime.to_unix(dt, :second)"]

      # The optional trailing Calendar on from_unix/3 leaves the unit at position 1.
      assert mode("DateTime.from_unix(ts, :second, Calendar.ISO)", false) ==
               ["DateTime.from_unix(ts, :millisecond, Calendar.ISO)"]
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

    test "sort order shorthand swaps :asc <-> :desc" do
      assert mode("Enum.sort(xs, :desc)", false) == ["Enum.sort(xs, :asc)"]
      assert mode("Enum.sort_by(xs, f, :asc)", false) == ["Enum.sort_by(xs, f, :desc)"]
      assert mode("List.keysort(xs, 0, :desc)", false) == ["List.keysort(xs, 0, :asc)"]

      # piped: `xs |> Enum.sort(:desc)` — the order atom is the lone visible arg.
      assert mode("Enum.sort(:desc)", true) == ["Enum.sort(:asc)"]
    end

    test "sort order: the {direction, module} tuple swaps the direction, keeping the module" do
      assert mode("Enum.sort(xs, {:desc, Date})", false) == ["Enum.sort(xs, {:asc, Date})"]

      assert mode("Enum.sort_by(xs, f, {:asc, Date})", false) ==
               ["Enum.sort_by(xs, f, {:desc, Date})"]

      # piped form keeps the tuple at the lone visible arg.
      assert mode("Enum.sort({:desc, Date})", true) == ["Enum.sort({:asc, Date})"]
    end

    test "sort order: a bare module sorter is wrapped descending (Date -> {:desc, Date})" do
      # `Enum.sort(xs, Date)` is the ascending default (≡ `{:asc, Date}`); the one
      # non-equivalent order swap is to wrap it descending.
      assert mode("Enum.sort(xs, Date)", false) == ["Enum.sort(xs, {:desc, Date})"]

      assert mode("Enum.sort_by(xs, f, Date)", false) ==
               ["Enum.sort_by(xs, f, {:desc, Date})"]

      # a nested alias and List.keysort are handled identically.
      assert mode("List.keysort(xs, 0, MyApp.Cmp)", false) ==
               ["List.keysort(xs, 0, {:desc, MyApp.Cmp})"]

      # piped form keeps the module at the lone visible arg.
      assert mode("Enum.sort(Date)", true) == ["Enum.sort({:desc, Date})"]
    end

    test "sort order: a sorter fun, variable, or no-sorter arity yields nothing" do
      assert ModeSwap.mutate(parse("Enum.sort_by(xs, f, &>=/2)"), %{pipe_mode: :unpiped}) == :skip

      # a variable sorter might hold `:asc` or a comparator fun — not wrapped.
      assert ModeSwap.mutate(parse("Enum.sort(xs, cmp)"), %{pipe_mode: :unpiped}) == :skip

      # Enum.sort/1 has no sorter; min_by/max_by reject the shorthand, so are not matched.
      assert ModeSwap.mutate(parse("Enum.sort(xs)"), %{pipe_mode: :unpiped}) == :skip
      assert ModeSwap.mutate(parse("Enum.min_by(xs, f, :desc)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "Base16/Base32 case: option value swaps :upper <-> :lower" do
      assert mode("Base.encode16(data, case: :lower)", false) ==
               ["Base.encode16(data, case: :upper)"]

      assert mode("Base.decode16(s, case: :upper)", false) == ["Base.decode16(s, case: :lower)"]
      assert mode("Base.decode16!(s, case: :lower)", false) == ["Base.decode16!(s, case: :upper)"]

      # The Base32 family reuses the same `case:` set.
      assert mode("Base.encode32(data, case: :lower)", false) ==
               ["Base.encode32(data, case: :upper)"]

      assert mode("Base.decode32(s, case: :upper)", false) == ["Base.decode32(s, case: :lower)"]
      assert mode("Base.decode32!(s, case: :lower)", false) == ["Base.decode32!(s, case: :upper)"]

      assert mode("Base.hex_encode32(data, case: :upper)", false) ==
               ["Base.hex_encode32(data, case: :lower)"]

      assert mode("Base.hex_decode32(s, case: :lower)", false) ==
               ["Base.hex_decode32(s, case: :upper)"]

      assert mode("Base.hex_decode32!(s, case: :upper)", false) ==
               ["Base.hex_decode32!(s, case: :lower)"]

      # piped: the options list is the lone visible arg.
      assert mode("Base.encode16(case: :upper)", true) == ["Base.encode16(case: :lower)"]

      # :mixed is deliberately left alone (accepts both cases — low-signal), on 16 and 32.
      assert ModeSwap.mutate(parse("Base.decode16(s, case: :mixed)"), %{pipe_mode: :unpiped}) ==
               :skip

      assert ModeSwap.mutate(parse("Base.decode32(s, case: :mixed)"), %{pipe_mode: :unpiped}) ==
               :skip
    end

    test "ISO 8601 format swaps :extended <-> :basic" do
      assert mode("DateTime.to_iso8601(dt, :extended)", false) ==
               ["DateTime.to_iso8601(dt, :basic)"]

      assert mode("DateTime.to_iso8601(dt, :basic)", false) ==
               ["DateTime.to_iso8601(dt, :extended)"]

      # /3 keeps the format at position 1; the trailing offset is untouched.
      assert mode("DateTime.to_iso8601(dt, :extended, 3600)", false) ==
               ["DateTime.to_iso8601(dt, :basic, 3600)"]

      # The NaiveDateTime/Time/Date twins (only /2 — no offset arity).
      assert mode("NaiveDateTime.to_iso8601(ndt, :basic)", false) ==
               ["NaiveDateTime.to_iso8601(ndt, :extended)"]

      assert mode("Time.to_iso8601(t, :extended)", false) == ["Time.to_iso8601(t, :basic)"]
      assert mode("Date.to_iso8601(d, :basic)", false) == ["Date.to_iso8601(d, :extended)"]

      # piped: `dt |> DateTime.to_iso8601(:basic)` — the format is the lone visible arg.
      assert mode("DateTime.to_iso8601(:basic)", true) == ["DateTime.to_iso8601(:extended)"]

      # /1 has no format arg; an unrecognised format has no sibling.
      assert ModeSwap.mutate(parse("DateTime.to_iso8601(dt)"), %{pipe_mode: :unpiped}) == :skip

      assert ModeSwap.mutate(parse("DateTime.to_iso8601(dt, :bogus)"), %{pipe_mode: :unpiped}) ==
               :skip
    end

    test "Regex return: option value swaps :index <-> :binary" do
      assert mode("Regex.scan(re, str, return: :index)", false) ==
               ["Regex.scan(re, str, return: :binary)"]

      assert mode("Regex.run(re, str, return: :binary)", false) ==
               ["Regex.run(re, str, return: :index)"]
    end

    test "Regex split on: toggles whole-match splitting" do
      # The whole-match modes move to :none (split on nothing).
      assert mode("Regex.split(re, str, on: :first)", false) ==
               ["Regex.split(re, str, on: :none)"]

      assert mode("Regex.split(re, str, on: :all)", false) ==
               ["Regex.split(re, str, on: :none)"]

      # The rest move to :first (the default — split on the whole match).
      assert mode("Regex.split(re, str, on: :none)", false) ==
               ["Regex.split(re, str, on: :first)"]

      assert mode("Regex.split(re, str, on: :all_but_first)", false) ==
               ["Regex.split(re, str, on: :first)"]

      assert mode("Regex.split(re, str, on: :all_names)", false) ==
               ["Regex.split(re, str, on: :first)"]

      # piped: `re |> Regex.split(str, on: :first)` — the regex is the piped value, so
      # the options list is still at effective position 2 (visible index 1).
      assert mode("Regex.split(str, on: :first)", true) == ["Regex.split(str, on: :none)"]

      # A list of capture references is not a mode atom, so it is left alone; so is /2.
      assert ModeSwap.mutate(parse(~s|Regex.split(re, str, on: ["x"])|), %{pipe_mode: :unpiped}) ==
               :skip

      assert ModeSwap.mutate(parse("Regex.split(re, str)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "week-start day swaps to an adjacent weekday" do
      assert mode("Date.beginning_of_week(d, :monday)", false) ==
               ["Date.beginning_of_week(d, :tuesday)"]

      assert mode("Date.end_of_week(d, :wednesday)", false) ==
               ["Date.end_of_week(d, :tuesday)", "Date.end_of_week(d, :thursday)"]

      assert mode("Date.day_of_week(d, :sunday)", false) == ["Date.day_of_week(d, :saturday)"]

      # `:default` ≡ `:monday`, so it maps to a concrete neighbour (`:tuesday`), not itself.
      assert mode("Date.day_of_week(d, :default)", false) == ["Date.day_of_week(d, :tuesday)"]

      # piped: `d |> Date.beginning_of_week(:monday)` — the weekday is the lone visible arg.
      assert mode("Date.beginning_of_week(:monday)", true) ==
               ["Date.beginning_of_week(:tuesday)"]

      # /1 defaults the day (no atom to swap); an unrecognised atom has no neighbour.
      assert ModeSwap.mutate(parse("Date.day_of_week(d)"), %{pipe_mode: :unpiped}) == :skip

      assert ModeSwap.mutate(parse("Date.day_of_week(d, :bogus)"), %{pipe_mode: :unpiped}) ==
               :skip
    end

    test "URL query encoding swaps :www_form <-> :rfc3986" do
      assert mode("URI.encode_query(q, :www_form)", false) == ["URI.encode_query(q, :rfc3986)"]
      assert mode("URI.encode_query(q, :rfc3986)", false) == ["URI.encode_query(q, :www_form)"]

      # decode_query's encoding is the 3rd argument.
      assert mode("URI.decode_query(s, %{}, :www_form)", false) ==
               ["URI.decode_query(s, %{}, :rfc3986)"]

      # piped: `q |> URI.encode_query(:rfc3986)`
      assert mode("URI.encode_query(:rfc3986)", true) == ["URI.encode_query(:www_form)"]

      # /1 defaults the encoding (no atom to swap).
      assert ModeSwap.mutate(parse("URI.encode_query(q)"), %{pipe_mode: :unpiped}) == :skip
    end

    test "keyword-option modes: a missing/variable/unrecognised value yields nothing" do
      # an option list without the named key
      assert ModeSwap.mutate(parse("Regex.scan(re, str, capture: :all)"), %{pipe_mode: :unpiped}) ==
               :skip

      # a variable value, not a literal atom
      assert ModeSwap.mutate(parse("Base.encode16(data, case: c)"), %{pipe_mode: :unpiped}) ==
               :skip

      # a non-keyword-list options argument
      assert ModeSwap.mutate(parse("Base.encode16(data, opts)"), %{pipe_mode: :unpiped}) == :skip
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

    test "every @rule_groups group routes to a swaps/2 clause (no drift)" do
      # The @rule_groups table and the swaps/2 dispatch are two separate edits with no
      # compile-time guard — a new rule group whose swaps/2 clause is forgotten compiles
      # fine and only raises (the catch-all ArgumentError) when a mutant exercises it.
      # This turns that latent runtime failure into a failing test.
      assert ModeSwap.uncovered_swap_groups() == []
    end
  end

  describe "Numeric" do
    test "Float.ceil ↔ Float.floor swap via mutate/2 (arity-blind rename)" do
      assert numeric("Float.ceil(x)", false) == ["Float.floor(x)"]
      assert numeric("Float.floor(x)", false) == ["Float.ceil(x)"]
      # Any arity — the /2 precision form renames too.
      assert numeric("Float.ceil(x, 2)", false) == ["Float.floor(x, 2)"]
      assert numeric("Float.floor(x, 2)", false) == ["Float.ceil(x, 2)"]
    end

    test "Float.round and unrelated Float/other calls are not swapped" do
      assert numeric_mutations("Float.round(x, 2)", false) == :skip
      assert numeric_mutations("Float.to_string(x)", false) == :skip
      assert numeric_mutations("Other.ceil(x)", false) == :skip
    end

    test "Kernel-qualified calls swap via mutate/2 (arity-blind, qualifier proves it)" do
      assert numeric("Kernel.min(a, b)", false) == ["Kernel.max(a, b)"]
      assert numeric("Kernel.max(a, b)", false) == ["Kernel.min(a, b)"]
      assert numeric("Kernel.round(x)", false) == ["Kernel.trunc(x)"]
      assert numeric("Kernel.trunc(x)", false) == ["Kernel.round(x)"]
      assert numeric("Kernel.ceil(x)", false) == ["Kernel.floor(x)"]
      assert numeric("Kernel.floor(x)", false) == ["Kernel.ceil(x)"]
    end

    test "does not expose mutate/1" do
      refute function_exported?(Numeric, :mutate, 1)
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
      assert numeric_mutations("min(a, b, c)", false) == :skip
      assert numeric_mutations("floor(x, y)", false) == :skip
      assert numeric_mutations("round(x, y)", false) == :skip
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
      assert numeric_mutations("floor(x)", true) == :skip
    end

    test "skips operators and non-numeric calls" do
      assert numeric_mutations("a + b", false) == :skip
      assert numeric_mutations("foo(a, b)", false) == :skip
      assert numeric_mutations("abs(x)", false) == :skip
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

  describe "IntegerCall" do
    test "mod ↔ floor_div swap (arity-blind rename, args preserved)" do
      assert render(IntegerCall.mutate(parse("Integer.mod(a, b)"))) == ["Integer.floor_div(a, b)"]
      assert render(IntegerCall.mutate(parse("Integer.floor_div(a, b)"))) == ["Integer.mod(a, b)"]
    end

    test "is_even ↔ is_odd swap (the guard-safe parity predicates)" do
      assert render(IntegerCall.mutate(parse("Integer.is_even(n)"))) == ["Integer.is_odd(n)"]
      assert render(IntegerCall.mutate(parse("Integer.is_odd(n)"))) == ["Integer.is_even(n)"]
    end

    test "skips unrelated Integer calls and other modules" do
      assert IntegerCall.mutate(parse("Integer.gcd(a, b)")) == :skip
      assert IntegerCall.mutate(parse("Integer.parse(s)")) == :skip
      assert IntegerCall.mutate(parse("Enum.mod(a, b)")) == :skip
      assert IntegerCall.mutate(parse(":math.sin(x)")) == :skip
    end

    test "skips non-call nodes" do
      assert IntegerCall.mutate(parse("a + b")) == :skip
      assert IntegerCall.mutate(parse("n")) == :skip
      assert IntegerCall.mutate(:atom) == :skip
    end

    test "name" do
      assert IntegerCall.name() == :integer_call
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

  defp kwdel(src, piped?),
    do: render(Mutare.Mutators.KeywordDelete.mutate(parse(src), context(piped?)))

  defp numeric(src, piped?),
    do: render(numeric_mutations(src, piped?))

  defp numeric_mutations(src, piped?),
    do: Mutare.Mutators.Numeric.mutate(parse(src), context(piped?))

  defp context(true), do: %{pipe_mode: :piped}
  defp context(false), do: %{pipe_mode: :unpiped}
end
