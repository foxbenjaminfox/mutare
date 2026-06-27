defmodule Mutare.IgnorePropertyTest do
  @moduledoc """
  Property-based coverage of the `# mutare:ignore[...]` directive **syntax** — the filter
  grammar and its matching: parsing, filter token round-tripping, bare-vs-qualified
  `[family:label]` matching, most-specific selection (with the source-order tie-break),
  case-folding, `ineffective/2`'s no-match complement, and `validate!/3`'s
  known-family/undeclared-label boundary.

  Unlike the `transform_*property` soaks (which render and compile a stream of generated
  modules, ~2 min), these are **pure and fast** — they only parse comment metadata and exercise
  the `Mutare.Ignore` pure functions — so they run in the normal async suite, *not* under the
  `:property` tag (which marks the slow render/compile soaks the fast loop excludes).
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.Ignore
  alias Mutare.Ignore.Directive
  alias Mutare.Ignore.SpecError

  @numtests 200

  # The variant vocabulary for the built-in set — the same map `Mutare.Transform` validates against.
  @vocab Mutare.Mutators.vocabulary(Mutare.Mutators.resolve([:builtins]))

  # Every filter-token name space: the built-in family atoms plus the unregistered `clause_drop`.
  @families Mutare.Mutators.families() ++ [:clause_drop]

  # A wire-safe, colon-free filter-token alphabet: lowercase letters, digits, and the operator
  # symbols real labels use (`>`, `>=`, `!==`, `&&&`, `++`, …). Excludes every char the grammar
  # forbids (`[\s,()\]":]` plus `:`), so a generated token always parses as exactly one entry.
  @token_chars Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ ~c"<>=!&|+-*/~"

  # --- generators -----------------------------------------------------------

  defp one_family, do: oneof(@families)

  # A non-empty token over the safe alphabet — a variant label or an arbitrary family token.
  defp token, do: let(cs <- non_empty(list(oneof(@token_chars))), do: List.to_string(cs))

  # A non-empty *word* (letters only), so up/down-casing it actually changes it.
  defp word, do: let(cs <- non_empty(list(oneof(Enum.to_list(?a..?z)))), do: List.to_string(cs))

  # A bounded (1–3 element) list, so the pure properties stay fast and shrink small.
  defp small_list(gen), do: let(n <- oneof([1, 2, 3]), do: vector(n, gen))

  # A canonical `{family, target}` filter entry: a bare family (`:any`) or a qualified label.
  defp entry do
    let f <- one_family() do
      fam = to_string(f)
      oneof([exactly({fam, :any}), let(l <- token(), do: {fam, l})])
    end
  end

  # A query target: a concrete label, `nil` (an unlabeled site), or the `:any` family query.
  defp target_gen, do: oneof([token(), exactly(nil), exactly(:any)])

  # A family *token* — sometimes a real family, sometimes an arbitrary (almost-surely unknown)
  # one — so the validation boundary sees known and unknown families alike.
  defp family_token, do: oneof([let(f <- one_family(), do: to_string(f)), token()])

  # `:all` or a small non-empty set of entries — one directive's `mutators`.
  defp mutators_gen,
    do: oneof([exactly(:all), let(es <- small_list(entry()), do: MapSet.new(es))])

  # A few directives sharing line 1, each with a distinct `source_order` so the tie-break is
  # well-defined and the structs are distinct (membership in `ineffective`/`directive_for` is exact).
  defp directives_on_one_line do
    let bodies <- small_list(mutators_gen()) do
      bodies
      |> Enum.with_index()
      |> Enum.map(fn {m, i} -> directive(1, m, i) end)
    end
  end

  # Directives spread over a few lines (1–3), each a distinct struct.
  defp directives_multiline do
    let parts <- small_list({oneof([1, 2, 3]), mutators_gen()}) do
      parts
      |> Enum.with_index()
      |> Enum.map(fn {{line, m}, i} -> directive(line, m, i) end)
    end
  end

  # `{line, mutator, variant}` site tuples (possibly empty — a line with no mutants).
  defp occupied_gen,
    do:
      let(n <- oneof([0, 1, 2, 3]), do: vector(n, {oneof([1, 2, 3]), one_family(), target_gen()}))

  defp directive(line, mutators, order),
    do: %Directive{line: line, mutators: mutators, reason: "r#{order}", source_order: order}

  # --- properties -----------------------------------------------------------

  property "a filter entry round-trips through entry_label and the parser", numtests: @numtests do
    forall e <- entry() do
      %Directive{mutators: set} = sole("x = 1 # mutare:ignore[#{Directive.entry_label(e)}]")
      MapSet.to_list(set) == [e]
    end
  end

  property "a filter parses to exactly its set of entries (any separator)", numtests: @numtests do
    forall {entries, sep} <- {small_list(entry()), oneof([", ", ",", " ", " , "])} do
      body = Enum.map_join(entries, sep, &Directive.entry_label/1)
      %Directive{mutators: set} = sole("x = 1 # mutare:ignore[#{body}]")
      set == MapSet.new(entries)
    end
  end

  property "bare [family] admits every target; qualified [family:label] admits only its label",
    numtests: @numtests do
    forall {fam, label, target} <- {one_family(), token(), target_gen()} do
      bare = sole("x = 1 # mutare:ignore[#{fam}]")
      qual = sole("x = 1 # mutare:ignore[#{fam}:#{label}]")
      dl = String.downcase(label)

      # A bare family admits *any* target (a label, an unlabeled `nil`, or the `:any` query);
      # a qualifier admits its own label and the `:any` family query, and nothing else.
      Directive.applies_to?(bare, fam, target) and
        Directive.applies_to?(qual, fam, dl) and
        Directive.applies_to?(qual, fam, :any) and
        Directive.applies_to?(qual, fam, target) == (target == :any or target == dl)
    end
  end

  property "directive_for returns the most-specific applicable directive, ties by source order",
    numtests: @numtests do
    forall {ds, mutator, target} <- {directives_on_one_line(), one_family(), target_gen()} do
      chosen = Ignore.directive_for(%{1 => ds}, 1, mutator, target)
      applicable = Enum.filter(ds, &Directive.applies_to?(&1, mutator, target))

      case applicable do
        [] ->
          chosen == nil

        _ ->
          max_spec =
            applicable
            |> Enum.map(&Directive.match_specificity(&1, mutator, target))
            |> Enum.max()

          expected_order =
            applicable
            |> Enum.filter(&(Directive.match_specificity(&1, mutator, target) == max_spec))
            |> Enum.map(& &1.source_order)
            |> Enum.min()

          chosen != nil and
            Directive.match_specificity(chosen, mutator, target) == max_spec and
            chosen.source_order == expected_order
      end
    end
  end

  property "matching is case-insensitive in family and label", numtests: @numtests do
    forall {fam, label} <- {one_family(), word()} do
      d = sole("x = 1 # mutare:ignore[#{String.upcase(to_string(fam))}:#{String.upcase(label)}]")

      Directive.applies_to?(d, fam, String.downcase(label)) and
        not Directive.applies_to?(d, fam, String.downcase(label) <> "x")
    end
  end

  property "validate! raises exactly when a known family carries an undeclared label",
    numtests: @numtests do
    forall {fam_tok, label} <- {family_token(), token()} do
      f = String.downcase(fam_tok)

      declared =
        case Map.get(@vocab, f) do
          %MapSet{} = labels -> labels
          _ -> MapSet.new()
        end

      should_raise =
        Map.has_key?(@vocab, f) and not MapSet.member?(declared, String.downcase(label))

      directives = Ignore.directives("x = 1 # mutare:ignore[#{fam_tok}:#{label}]")

      raised? =
        try do
          Ignore.validate!(directives, @vocab, "f.ex")
          false
        rescue
          SpecError -> true
        end

      raised? == should_raise
    end
  end

  property "a bare-only filter is never qualified and never raises validate!",
    numtests: @numtests do
    forall fams <- small_list(one_family()) do
      body = Enum.map_join(fams, ", ", &to_string/1)
      directives = Ignore.directives("x = 1 # mutare:ignore[#{body}]")

      not Ignore.any_qualified?(directives) and
        Ignore.validate!(directives, @vocab, "f.ex") == :ok
    end
  end

  property "a directive is ineffective exactly when no occupied site on its line matches it",
    numtests: @numtests do
    forall {ds, occupied} <- {directives_multiline(), occupied_gen()} do
      ineffective = Ignore.ineffective(Enum.group_by(ds, & &1.line), occupied)

      Enum.all?(ds, fn d ->
        matched =
          Enum.any?(occupied, fn {l, m, t} -> l == d.line and Directive.applies_to?(d, m, t) end)

        d in ineffective == not matched
      end)
    end
  end

  # The single directive a one-line trailing `# mutare:ignore[...]` source produces.
  defp sole(src), do: src |> Ignore.directives() |> Map.fetch!(1) |> hd()
end
