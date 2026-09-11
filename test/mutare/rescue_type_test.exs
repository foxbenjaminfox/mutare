defmodule Mutare.RescueTypeTest do
  @moduledoc """
  `Mutare.Mutators.RescueType` narrows a `rescue var in [A, B, ...]` exception list by dropping
  one type. A rescue clause is special — it matches on exception types and carries no `when`
  guard — so the mutant is delivered by the whole-construct selector (the whole `try` wrapped,
  its mutant branch a copy with one rescue clause's type list shrunk). Proven with one compile
  and runtime switching.
  """
  # persistent_term is global; the fixture is compiled once for all tests.
  use ExUnit.Case, async: false
  import Mutare.Test.Metamutant

  alias Mutare.{Report, Selector, Site}

  @source """
  defmodule Mutare.RescueTypeFixture do
    def run(f) do
      try do
        f.()
      rescue
        e in [RuntimeError, ArgumentError] -> {:caught, e.__struct__}
      end
    end

    def single(f) do
      try do
        f.()
      rescue
        RuntimeError -> :only_runtime
      end
    end

    def def_body(f) do
      f.()
    rescue
      e in [RuntimeError, ArgumentError] -> {:def_caught, e.__struct__}
    end

    def bare(f) do
      try do
        f.()
      rescue
        [RuntimeError, ArgumentError] -> :bare_caught
      end
    end

    def branches(f) do
      try do
        f.()
      rescue
        e in ArgumentError -> {:branch_arg, e.__struct__}
        e in RuntimeError -> {:branch_run, e.__struct__}
      end
    end

    def def_branches(f) do
      f.()
    rescue
      e in ArgumentError -> {:db_arg, e.__struct__}
      e in RuntimeError -> {:db_run, e.__struct__}
    end

    def def_inline(f),
      do: f.(),
      rescue: (e in [RuntimeError, ArgumentError] -> {:inline_caught, e.__struct__})

    def def_inline_branches(f),
      do: f.(),
      rescue:
        (e in ArgumentError ->
           {:dib_arg, e.__struct__}

         e in RuntimeError ->
           {:dib_run, e.__struct__})
  end
  """

  @compile {:no_warn_undefined, Mutare.RescueTypeFixture}

  setup_all do
    %{metamutant: metamutant, sites: sites} =
      Mutare.Transform.transform_string_with_sites(@source, file: "rt.ex")

    assert_compiles(metamutant)

    %{sites: sites, meta: metamutant}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  alias Mutare.RescueTypeFixture, as: F

  # Run `F.run/1` raising `ex`, reporting whether the rescue caught it or it propagated.
  defp outcome(ex) do
    {:caught, F.run(fn -> raise ex end)}
  rescue
    e -> {:propagated, e.__struct__}
  end

  # Same, for `F.bare/1` (the bare-list `rescue [A, B] ->` form, no `var in` binding).
  defp bare_outcome(ex) do
    {:caught, F.bare(fn -> raise ex end)}
  rescue
    e -> {:propagated, e.__struct__}
  end

  # Same, for `F.branches/1` (the multi-branch `rescue e in A -> …; e in B -> …` form).
  defp branch_outcome(ex) do
    {:caught, F.branches(fn -> raise ex end)}
  rescue
    e -> {:propagated, e.__struct__}
  end

  # Same, for `F.def_body/1` (the `def … rescue …` shorthand, a two-type list).
  defp def_body_outcome(ex) do
    {:caught, F.def_body(fn -> raise ex end)}
  rescue
    e -> {:propagated, e.__struct__}
  end

  # Same, for `F.def_branches/1` (the multi-branch `def … rescue …` shorthand).
  defp def_branch_outcome(ex) do
    {:caught, F.def_branches(fn -> raise ex end)}
  rescue
    e -> {:propagated, e.__struct__}
  end

  # Same, for `F.def_inline/1` (the **inline keyword** `def …, rescue: (…)` shorthand,
  # whose clause list Sourceror wraps in a `{:__block__, _, [clauses]}`).
  defp def_inline_outcome(ex) do
    {:caught, F.def_inline(fn -> raise ex end)}
  rescue
    e -> {:propagated, e.__struct__}
  end

  # Same, for `F.def_inline_branches/1` (the inline-keyword multi-branch shorthand).
  defp def_inline_branch_outcome(ex) do
    {:caught, F.def_inline_branches(fn -> raise ex end)}
  rescue
    e -> {:propagated, e.__struct__}
  end

  defp rescue_site(sites, mutated_code, line) do
    site =
      Enum.find(
        sites,
        &(&1.mutator == :rescue_type and &1.mutated_code == mutated_code and &1.line == line)
      )

    assert site, "no rescue_type site #{inspect(mutated_code)} on line #{line}"
    site.id
  end

  # A whole-clause-drop site (`operation: :delete`) on the given line.
  defp rescue_drop_site(sites, line) do
    site =
      Enum.find(
        sites,
        &(&1.mutator == :rescue_type and &1.operation == :delete and &1.line == line)
      )

    assert site, "no rescue_type clause-drop site on line #{line}"
    site.id
  end

  test "baseline catches both exception types" do
    assert {:caught, {:caught, RuntimeError}} = outcome(RuntimeError)
    assert {:caught, {:caught, ArgumentError}} = outcome(ArgumentError)
  end

  test "dropping a type makes that exception propagate while the other is still caught", %{
    sites: sites
  } do
    Selector.put(rescue_site(sites, "e in [RuntimeError]", 6))
    assert {:caught, {:caught, RuntimeError}} = outcome(RuntimeError)
    assert {:propagated, ArgumentError} = outcome(ArgumentError)

    Selector.put(rescue_site(sites, "e in [ArgumentError]", 6))
    assert {:propagated, RuntimeError} = outcome(RuntimeError)
    assert {:caught, {:caught, ArgumentError}} = outcome(ArgumentError)
  end

  test "an unknown id falls through to the original (both caught)" do
    Selector.put(987_654)
    assert {:caught, {:caught, RuntimeError}} = outcome(RuntimeError)
    assert {:caught, {:caught, ArgumentError}} = outcome(ArgumentError)
  end

  test "a single-type rescue is not mutated (nothing to narrow to)", %{sites: sites} do
    refute Enum.any?(sites, &(&1.mutator == :rescue_type and &1.line == 14))
  end

  test "two type-drop mutants are produced for a two-type list", %{sites: sites} do
    drops = Enum.filter(sites, &(&1.mutator == :rescue_type and &1.line == 6))
    assert length(drops) == 2
    assert Enum.all?(drops, &(&1.kind == :in_place))
  end

  test "renders a rescue type-drop as a focused one-line diff", %{sites: sites} do
    site =
      Enum.find(
        sites,
        &(&1.mutator == :rescue_type and &1.line == 6 and &1.mutated_code == "e in [RuntimeError]")
      )

    assert Report.header(site) == "rt.ex:6  [rescue_type, in-place]  SURVIVED"

    assert Report.diff(site, @source) ==
             "-      e in [RuntimeError, ArgumentError] -> {:caught, e.__struct__}\n" <>
               "+      e in [RuntimeError] -> {:caught, e.__struct__}"
  end

  describe "bare-list rescue form (`rescue [A, B] ->`, no `var in`)" do
    test "baseline catches both exception types" do
      assert {:caught, :bare_caught} = bare_outcome(RuntimeError)
      assert {:caught, :bare_caught} = bare_outcome(ArgumentError)
    end

    test "two type-drop mutants are produced for a bare two-type list", %{sites: sites} do
      drops = Enum.filter(sites, &(&1.mutator == :rescue_type and &1.line == 28))
      assert length(drops) == 2
      assert Enum.all?(drops, &(&1.kind == :in_place))
    end

    test "dropping a type makes that exception propagate while the other is still caught", %{
      sites: sites
    } do
      Selector.put(rescue_site(sites, "[RuntimeError]", 28))
      assert {:caught, :bare_caught} = bare_outcome(RuntimeError)
      assert {:propagated, ArgumentError} = bare_outcome(ArgumentError)

      Selector.put(rescue_site(sites, "[ArgumentError]", 28))
      assert {:propagated, RuntimeError} = bare_outcome(RuntimeError)
      assert {:caught, :bare_caught} = bare_outcome(ArgumentError)
    end

    test "renders a bare-list type-drop as a focused one-line diff", %{sites: sites} do
      site =
        Enum.find(
          sites,
          &(&1.mutator == :rescue_type and &1.line == 28 and &1.mutated_code == "[RuntimeError]")
        )

      assert Report.header(site) == "rt.ex:28  [rescue_type, in-place]  SURVIVED"

      assert Report.diff(site, @source) ==
               "-      [RuntimeError, ArgumentError] -> :bare_caught\n" <>
                 "+      [RuntimeError] -> :bare_caught"
    end
  end

  describe "multi-branch rescue (`rescue e in A -> …; e in B -> …`): drop a whole clause" do
    test "baseline catches both exception types" do
      assert {:caught, {:branch_arg, ArgumentError}} = branch_outcome(ArgumentError)
      assert {:caught, {:branch_run, RuntimeError}} = branch_outcome(RuntimeError)
    end

    test "a single-type-per-branch rescue yields no type-list narrowings", %{sites: sites} do
      # Each branch catches one type — there is no `in [A, B]` list to narrow, so the only
      # rescue mutations on these clauses are whole-clause drops (`operation: :delete`).
      branch = Enum.filter(sites, &(&1.mutator == :rescue_type and &1.line in [36, 37]))
      assert branch != []
      assert Enum.all?(branch, &(&1.operation == :delete))
    end

    test "one whole-clause-drop mutant per branch, delivered in place", %{sites: sites} do
      drops = Enum.filter(sites, &(&1.mutator == :rescue_type and &1.line in [36, 37]))
      assert length(drops) == 2
      assert Enum.all?(drops, &(&1.kind == :in_place and &1.operation == :delete))
    end

    test "dropping a branch makes its exception propagate while the other is still caught", %{
      sites: sites
    } do
      Selector.put(rescue_drop_site(sites, 36))
      assert {:propagated, ArgumentError} = branch_outcome(ArgumentError)
      assert {:caught, {:branch_run, RuntimeError}} = branch_outcome(RuntimeError)

      Selector.put(rescue_drop_site(sites, 37))
      assert {:caught, {:branch_arg, ArgumentError}} = branch_outcome(ArgumentError)
      assert {:propagated, RuntimeError} = branch_outcome(RuntimeError)
    end

    test "renders a clause-drop as a `-` deletion of the whole branch", %{sites: sites} do
      site = Enum.find(sites, &(&1.id == rescue_drop_site(sites, 36)))

      assert Report.header(site) == "rt.ex:36  [rescue_type, in-place]  SURVIVED"

      assert Report.diff(site, @source) ==
               "-      e in ArgumentError -> {:branch_arg, e.__struct__}"

      assert Site.describe(site) ==
               "rescue_type  (drop) e in ArgumentError -> {:branch_arg, e.__struct__}"
    end

    test "a single-clause `try` is never offered a clause-drop", %{sites: sites} do
      # `run/1` (line 6) has one rescue clause — dropping it would leave an empty `rescue`,
      # so only type-list narrowings are produced there, never a `:delete`.
      refute Enum.any?(
               sites,
               &(&1.mutator == :rescue_type and &1.operation == :delete and &1.line == 6)
             )
    end
  end

  describe "`def … rescue …` shorthand (hosted in a synthesized `try`)" do
    test "a two-type list in a shorthand rescue is narrowed", %{sites: sites} do
      drops = Enum.filter(sites, &(&1.mutator == :rescue_type and &1.line == 21))
      assert length(drops) == 2
      assert Enum.all?(drops, &(&1.kind == :in_place and &1.operation == :replace))
    end

    test "narrowing a shorthand rescue propagates the dropped type at runtime", %{sites: sites} do
      Selector.put(rescue_site(sites, "e in [RuntimeError]", 21))
      assert {:caught, {:def_caught, RuntimeError}} = def_body_outcome(RuntimeError)
      assert {:propagated, ArgumentError} = def_body_outcome(ArgumentError)

      Selector.put(rescue_site(sites, "e in [ArgumentError]", 21))
      assert {:propagated, RuntimeError} = def_body_outcome(RuntimeError)
      assert {:caught, {:def_caught, ArgumentError}} = def_body_outcome(ArgumentError)
    end

    test "a shorthand still gets its granular return-value mutants (no regression)", %{
      sites: sites
    } do
      # The do-body tail (`f.()`, line 19) and the rescue-clause tail (line 21) are both
      # return positions — hosting the body in a synthesized `try` must not lose them.
      returns = Enum.filter(sites, &(&1.mutator == :return_value and &1.line in [19, 21]))
      assert Enum.any?(returns, &(&1.line == 19)), "do-body tail return mutant missing"
      assert Enum.any?(returns, &(&1.line == 21)), "rescue-clause tail return mutant missing"
    end

    test "a multi-branch shorthand drops each whole clause", %{sites: sites} do
      drops = Enum.filter(sites, &(&1.mutator == :rescue_type and &1.line in [44, 45]))
      assert length(drops) == 2
      assert Enum.all?(drops, &(&1.kind == :in_place and &1.operation == :delete))
    end

    test "dropping a shorthand branch propagates its exception at runtime", %{sites: sites} do
      Selector.put(rescue_drop_site(sites, 44))
      assert {:propagated, ArgumentError} = def_branch_outcome(ArgumentError)
      assert {:caught, {:db_run, RuntimeError}} = def_branch_outcome(RuntimeError)

      Selector.put(rescue_drop_site(sites, 45))
      assert {:caught, {:db_arg, ArgumentError}} = def_branch_outcome(ArgumentError)
      assert {:propagated, RuntimeError} = def_branch_outcome(RuntimeError)
    end

    test "renders a shorthand narrowing as a focused one-line diff", %{sites: sites} do
      site =
        Enum.find(
          sites,
          &(&1.mutator == :rescue_type and &1.line == 21 and
              &1.mutated_code == "e in [RuntimeError]")
        )

      assert Report.diff(site, @source) ==
               "-    e in [RuntimeError, ArgumentError] -> {:def_caught, e.__struct__}\n" <>
                 "+    e in [RuntimeError] -> {:def_caught, e.__struct__}"
    end
  end

  describe "inline-keyword `def …, rescue: (…)` shorthand (Sourceror block-wraps the clause list)" do
    test "a two-type list in an inline-keyword rescue is narrowed", %{sites: sites} do
      drops = Enum.filter(sites, &(&1.mutator == :rescue_type and &1.line == 50))
      assert length(drops) == 2
      assert Enum.all?(drops, &(&1.kind == :in_place and &1.operation == :replace))
    end

    test "the block-wrapped clause list is not analyzed as a runtime list literal", %{
      sites: sites
    } do
      # Regression: before `normalize_clause_blocks/1` the inline rescue value (Sourceror's
      # `{:__block__, _, [clauses]}`) fell through `analyze_do_blocks/2`'s `is_list` guard and
      # was analyzed as a runtime expression — so the clause *list* drew a `:list`→`[]` mutant
      # and a selector `case` was spliced around the `->` clauses, poison. The list must never
      # be a mutand, and the rescue narrowings (above) must appear instead.
      refute Enum.any?(sites, &(&1.mutator == :list and &1.line == 50))
    end

    test "narrowing an inline-keyword rescue propagates the dropped type at runtime", %{
      sites: sites
    } do
      Selector.put(rescue_site(sites, "e in [RuntimeError]", 50))
      assert {:caught, {:inline_caught, RuntimeError}} = def_inline_outcome(RuntimeError)
      assert {:propagated, ArgumentError} = def_inline_outcome(ArgumentError)

      Selector.put(rescue_site(sites, "e in [ArgumentError]", 50))
      assert {:propagated, RuntimeError} = def_inline_outcome(RuntimeError)
      assert {:caught, {:inline_caught, ArgumentError}} = def_inline_outcome(ArgumentError)
    end

    test "an inline-keyword multi-branch shorthand drops each whole clause", %{sites: sites} do
      drops = Enum.filter(sites, &(&1.mutator == :rescue_type and &1.line in [55, 58]))
      assert length(drops) == 2
      assert Enum.all?(drops, &(&1.kind == :in_place and &1.operation == :delete))
    end

    test "dropping an inline-keyword branch propagates its exception at runtime", %{sites: sites} do
      Selector.put(rescue_drop_site(sites, 55))
      assert {:propagated, ArgumentError} = def_inline_branch_outcome(ArgumentError)
      assert {:caught, {:dib_run, RuntimeError}} = def_inline_branch_outcome(RuntimeError)

      Selector.put(rescue_drop_site(sites, 58))
      assert {:caught, {:dib_arg, ArgumentError}} = def_inline_branch_outcome(ArgumentError)
      assert {:propagated, RuntimeError} = def_inline_branch_outcome(RuntimeError)
    end

    test "an inline-keyword shorthand still gets its granular return-value mutants", %{
      sites: sites
    } do
      # The do-body tail (`f.()`, line 49) and the rescue-clause tail (line 50) are both
      # return positions — normalizing + hosting in a synthesized `try` must keep them.
      returns = Enum.filter(sites, &(&1.mutator == :return_value and &1.line in [49, 50]))
      assert Enum.any?(returns, &(&1.line == 49)), "do-body tail return mutant missing"
      assert Enum.any?(returns, &(&1.line == 50)), "rescue-clause tail return mutant missing"
    end
  end

  describe "drops/1 (direct)" do
    alias Mutare.Mutators.RescueType

    test "narrows each ≥2-type list by removing one type, keeping every result non-empty" do
      assert RescueType.drops([:A, :B, :C]) == [[:B, :C], [:A, :C], [:A, :B]]
    end

    test "returns [] for a single type or a non-list (dropping would leave `in []`)" do
      assert RescueType.drops([:Only]) == []
      assert RescueType.drops({:var, [], nil}) == []
    end
  end
end
