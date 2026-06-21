defmodule Mutare.NegativeFloatTest do
  @moduledoc """
  Regression: a literal mutator that drops a *negative* value back under an existing
  unary minus must still render a metamutant that **compiles** — the tool's whole bet
  is one compile, so a single un-renderable mutant sinks the run.

  Sourceror parses `-0.5` as a unary minus over a positive magnitude
  (`{:-, _, [{:__block__, _, [0.5]}]}`). `FloatLiteral` mutates the inner `0.5`, and
  one replacement is `0.5 - 1.0 == -0.5` — itself negative. Built as a bare
  `{:__block__, [], [-0.5]}` it renders fine alone but glues into `--0.5` (the
  list-subtraction token, invalid Elixir) the instant it lands under the parent minus.
  The two-sided fix this pins:

    * `Mutare.AST.literal/1` builds a negative as the parser's own `{:-, _, [mag]}`,
      so the formatter spaces the nested minuses into `-(-0.5)` and the source parses.
    * `Mutare.Transform.Tag.literal_node?/1` recognises that unary-minus-over-literal
      shape, so a negative replacement is still treated as a pattern-legal literal and
      isn't silently dropped from a head/clause-pattern mutant.

  The two halves surface in different positions, so each gets its own fixture:

    * A **guard** is the position where the double negative both occurs and is legal
      (`when x == -(-0.5)`): without the `AST.literal/1` fix it renders `--0.5` and the
      metamutant won't even parse.
    * A **head pattern** is where `literal_node?/1` matters: a positive literal mutated
      to a clean negative (`def f(0.0)` → `def f(-1.0)`) — without the `Tag` fix that
      mutant is dropped from the lifted clause group entirely.
  """
  # Compiles fixture modules and flips the global `:persistent_term` selector — serial.
  use ExUnit.Case, async: false

  alias Mutare.Selector

  # Pin to `FloatLiteral` alone so the float sites are the only mutants and their ids
  # are stable; the negative one (`→ -0.5` / `→ -1.0`) is the regression.
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

  @compile {:no_warn_undefined, [Mutare.NegFloatGuardFixture, Mutare.NegFloatHeadFixture]}

  setup_all do
    {guard_meta, guard_sites, _} =
      Mutare.transform_string(@guard_source, file: "guard.ex", mutators: @mutators)

    {head_meta, head_sites, _} =
      Mutare.transform_string(@head_source, file: "head.ex", mutators: @mutators)

    # Compile both — the real bet is one compile, so the metamutant must build, not
    # merely parse. (Captured: nothing should warn, but a stray warning shouldn't
    # clutter the run.)
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      [{_, _}] = Code.compile_string(guard_meta)
      [{_, _}] = Code.compile_string(head_meta)
    end)

    %{
      guard_meta: guard_meta,
      guard_sites: guard_sites,
      head_meta: head_meta,
      head_sites: head_sites
    }
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

  describe "AST.literal/1 — the double negative in a guard" do
    test "renders the negation as -(-0.5), never the invalid --0.5 token", %{guard_meta: meta} do
      refute meta =~ "--0.5"
      assert meta =~ "-(-0.5)"
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "the negated guard literal selects at runtime", %{guard_sites: sites} do
      alias Mutare.NegFloatGuardFixture, as: F

      # Baseline: the guard `x == -0.5` holds for -0.5.
      assert F.f(-0.5) == :a
      assert F.f(0.5) == :b

      # Mutant: `0.5 → -0.5` makes the guard `x == -(-0.5)` (== `x == 0.5`), flipping it.
      Selector.put(float_id(sites, "-0.5"))
      assert F.f(-0.5) == :b
      assert F.f(0.5) == :a
    end
  end

  describe "Tag.literal_node?/1 — a negative replacement in a head pattern" do
    test "the negative head-literal mutant survives the pattern filter", %{head_sites: sites} do
      # Both float replacements reach the head pattern; without the `Tag` fix the
      # negative one (`-1.0`) would be silently filtered out.
      mutated = sites |> Enum.filter(&(&1.mutator == :float)) |> Enum.map(& &1.mutated_code)
      assert Enum.sort(mutated) == ["-1.0", "1.0"]
    end

    test "the negated head literal selects at runtime", %{head_sites: sites} do
      alias Mutare.NegFloatHeadFixture, as: F

      assert F.f(0.0) == :a
      assert F.f(-1.0) == :b

      # Mutant: head `0.0` becomes `-1.0`, so the match moves off 0.0.
      Selector.put(float_id(sites, "-1.0"))
      assert F.f(0.0) == :b
      assert F.f(-1.0) == :a
    end
  end
end
