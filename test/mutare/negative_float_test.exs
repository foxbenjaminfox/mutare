defmodule Mutare.NegativeFloatTest do
  @moduledoc """
  Regression: mutating a literal at or under an existing unary minus must always
  render a metamutant that **compiles** — the tool's whole bet is one compile, so a
  single un-renderable / un-compilable mutant sinks the run.

  Sourceror parses `-0.5` as a unary minus over a positive magnitude
  (`{:-, _, [{:__block__, _, [0.5]}]}`). The literal families mutate the inner `0.5`,
  and one replacement (`0.5 - 1.0 == -0.5`) is itself negative — a negative dropped
  back under the parent minus. Three coupled fixes keep that legal, each pinned below:

    * `Mutare.AST.literal/1` builds a negative as the parser's own `{:-, _, [mag]}`,
      so the formatter spaces the nested minuses (`-(-0.5)`) and the source *parses*
      instead of gluing into the invalid list-subtraction token `--0.5`.
    * `Mutare.Transform.Tag.literal_node?/1` recognises that unary-minus-over-literal
      shape, so a negative replacement is treated as a pattern-legal literal and isn't
      silently dropped from a head/clause-pattern mutant.
    * In a **match** position, though, `-(-0.5)` *parses but won't compile*
      (`:erlang.-/1` can't run inside a pattern). So `Tag` mutates a negative literal
      in a pattern by **value** — the whole `-0.5` node, offered `0.5` / `-1.5` / `0.0`
      — never splicing a nested `-(-x)`. A **guard** keeps the in-place magnitude walk
      (`-(-0.5)` is a legal guard expression), so the two positions render differently
      but both compile.

  The fixtures put a negative float in each position where the nesting bites: a guard,
  a `def` head, and a `case` clause — plus a positive head literal mutated *to* a
  negative (the `literal_node?/1` path).
  """
  # Compiles fixture modules and flips the global `:persistent_term` selector — serial.
  use ExUnit.Case, async: false

  alias Mutare.Selector

  # Pin to `FloatLiteral` alone so the float sites are the only mutants and their ids
  # are stable; the negative replacements are the regression.
  @mutators [Mutare.Mutators.FloatLiteral]

  @guard_source """
  defmodule Mutare.NegFloatGuardFixture do
    def f(x) when x == -0.5, do: :a
    def f(_), do: :b
  end
  """

  @head_source """
  defmodule Mutare.NegFloatHeadFixture do
    def f(0.0), do: :a
    def f(_), do: :b
  end
  """

  @match_source """
  defmodule Mutare.NegFloatMatchFixture do
    def classify(-0.5), do: :neg_half
    def classify(_), do: :other
  end
  """

  @case_source """
  defmodule Mutare.NegFloatCaseFixture do
    def classify(x) do
      case x do
        -0.5 -> :neg_half
        _ -> :other
      end
    end
  end
  """

  @compile {:no_warn_undefined,
            [
              Mutare.NegFloatGuardFixture,
              Mutare.NegFloatHeadFixture,
              Mutare.NegFloatMatchFixture,
              Mutare.NegFloatCaseFixture
            ]}

  setup_all do
    metas =
      for {key, source, file} <- [
            {:guard, @guard_source, "guard.ex"},
            {:head, @head_source, "head.ex"},
            {:match, @match_source, "match.ex"},
            {:case, @case_source, "case.ex"}
          ],
          into: %{} do
        {meta, sites, _} =
          Mutare.Transform.transform_string_with_sites(source, file: file, mutators: @mutators)

        {key, %{meta: meta, sites: sites}}
      end

    # Compile every metamutant — the real bet is one compile, so each must build, not
    # merely parse. (Captured: nothing should warn, but a stray warning shouldn't
    # clutter the run.)
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      for {_key, %{meta: meta}} <- metas, do: [{_, _}] = Code.compile_string(meta)
    end)

    metas
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  defp float_id(sites, mutated_code) do
    site = Enum.find(sites, &(&1.mutator == :float and &1.mutated_code == mutated_code))
    assert site, "no float site mutating to #{inspect(mutated_code)}"
    site.id
  end

  defp mutated_codes(sites),
    do:
      sites |> Enum.filter(&(&1.mutator == :float)) |> Enum.map(& &1.mutated_code) |> Enum.sort()

  describe "AST.literal/1 — the double negative in a guard" do
    test "renders the negation as -(-0.5), never the invalid --0.5 token", %{guard: g} do
      refute g.meta =~ "--0.5"
      assert g.meta =~ "-(-0.5)"
      assert {:ok, _} = Code.string_to_quoted(g.meta)
    end

    test "the negated guard literal selects at runtime", %{guard: g} do
      alias Mutare.NegFloatGuardFixture, as: F

      # Baseline: the guard `x == -0.5` holds for -0.5.
      assert F.f(-0.5) == :a
      assert F.f(0.5) == :b

      # Mutant: `0.5 → -0.5` makes the guard `x == -(-0.5)` (== `x == 0.5`), flipping it.
      Selector.put(float_id(g.sites, "-0.5"))
      assert F.f(-0.5) == :b
      assert F.f(0.5) == :a
    end
  end

  describe "Tag.literal_node?/1 — a positive head literal mutated to a negative" do
    test "the negative head-literal mutant survives the pattern filter", %{head: h} do
      # Both float replacements reach the head pattern; without the `Tag` fix the
      # negative one (`-1.0`) would be silently filtered out.
      assert mutated_codes(h.sites) == ["-1.0", "1.0"]
    end

    test "the negated head literal selects at runtime", %{head: h} do
      alias Mutare.NegFloatHeadFixture, as: F

      assert F.f(0.0) == :a
      assert F.f(-1.0) == :b

      # Mutant: head `0.0` becomes `-1.0`, so the match moves off 0.0.
      Selector.put(float_id(h.sites, "-1.0"))
      assert F.f(0.0) == :b
      assert F.f(-1.0) == :a
    end
  end

  describe "Tag — a negative literal in a match position is value-mutated" do
    test "a negative head literal compiles with no illegal -(-x) in the match", %{match: m} do
      # The whole `-0.5` is mutated by value into clean self-contained literals, never
      # the `-(-0.5)` that parses but can't compile inside a pattern.
      refute m.meta =~ "-(-0.5)"
      assert mutated_codes(m.sites) == ["-1.5", "0.0", "0.5"]
      assert {:ok, _} = Code.string_to_quoted(m.meta)
    end

    test "a negative case-clause literal is value-mutated the same way", %{case: c} do
      refute c.meta =~ "-(-0.5)"
      assert mutated_codes(c.sites) == ["-1.5", "0.0", "0.5"]
    end

    test "the value-mutated head literal selects at runtime", %{match: m} do
      alias Mutare.NegFloatMatchFixture, as: F

      assert F.classify(-0.5) == :neg_half
      assert F.classify(0.5) == :other

      # Mutant: the whole head literal `-0.5` becomes `0.5`, flipping the match.
      Selector.put(float_id(m.sites, "0.5"))
      assert F.classify(-0.5) == :other
      assert F.classify(0.5) == :neg_half
    end

    test "the value-mutated case-clause literal selects at runtime", %{case: c} do
      alias Mutare.NegFloatCaseFixture, as: F

      assert F.classify(-0.5) == :neg_half
      assert F.classify(0.5) == :other

      Selector.put(float_id(c.sites, "0.5"))
      assert F.classify(-0.5) == :other
      assert F.classify(0.5) == :neg_half
    end
  end
end
