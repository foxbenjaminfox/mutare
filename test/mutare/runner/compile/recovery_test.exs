defmodule Mutare.Runner.Compile.RecoveryTest do
  # The poison-recovery decision, without a compile: `next_round/3` over hand-built and
  # generated attributions, sites, and states.
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.Runner.Compile.Recovery
  alias Mutare.Runner.Compile.Recovery.Plan
  alias Mutare.Site

  defp site(id, opts \\ []) do
    %Site{
      id: id,
      file: Keyword.get(opts, :file, "lib/a.ex"),
      line: Keyword.get(opts, :line, id),
      mutator: :arithmetic,
      block_macro: Keyword.get(opts, :block)
    }
  end

  defp attribution(opts) do
    %{
      line: MapSet.new(Keyword.get(opts, :line, [])),
      macro: for({macro, ids} <- Keyword.get(opts, :macro, []), do: {macro, MapSet.new(ids)}),
      clean: MapSet.new(Keyword.get(opts, :clean, []))
    }
  end

  describe "block-macro escalation" do
    setup do
      block = [site(1, block: {:dsl, 0}), site(2, block: {:dsl, 0}), site(3, block: {:dsl, 0})]
      sibling = [site(4, block: {:dsl, 1})]
      %{sites: block ++ sibling ++ [site(5)]}
    end

    test "the first strike drops only the attributed id and marks the block", %{sites: sites} do
      assert {:retry, plan} = Recovery.next_round(attribution(line: [1]), sites, %Recovery{})

      assert plan.ids == MapSet.new([1])
      assert plan.cause == {:line, MapSet.new()}
      assert plan.recovery.struck == MapSet.new([{"lib/a.ex", {:dsl, 0}}])
    end

    test "a second strike in the block drops the whole invocation, not its sibling", %{
      sites: sites
    } do
      {:retry, first} = Recovery.next_round(attribution(line: [1]), sites, %Recovery{})
      {:retry, second} = Recovery.next_round(attribution(line: [2]), sites, first.recovery)

      key = {"lib/a.ex", {:dsl, 0}}
      assert second.ids == MapSet.new([2, 3])
      assert second.cause == {:line, MapSet.new([key])}
      assert second.recovery.escalated == MapSet.new([key])
      assert second.recovery.skip_ids == MapSet.new([1, 2, 3])
    end

    test "the inline fallback leaves block-macro mutants to escalation", %{sites: sites} do
      macro = {"Ecto.Query", :from}
      attr = attribution(line: [1], macro: [{macro, [1, 2]}])

      assert {:retry, %Plan{cause: {:line, _}, ids: ids}} =
               Recovery.next_round(attr, sites, %Recovery{})

      assert ids == MapSet.new([1])
    end
  end

  describe "inline-macro precedence" do
    test "the macro's argument mutants drop; the outer selector the line names does not" do
      sites = [site(1), site(2)]
      macro = {"Ecto.Query", :from}
      attr = attribution(line: [1], macro: [{macro, [2]}])

      assert {:retry, plan} = Recovery.next_round(attr, sites, %Recovery{})
      assert plan.cause == {:inline_macro, [{macro, MapSet.new([2])}]}
      assert plan.ids == MapSet.new([2])
      assert plan.recovery.macro_skips == MapSet.new([macro])

      assert [{:macro_poison, %{macros: [%{module: "Ecto.Query", macro: :from, count: 1}]}}] =
               Recovery.announcements(plan, sites)
    end

    test "a macro whose ids are all dropped already yields to line attribution" do
      sites = [site(1), site(2)]
      attr = attribution(line: [1], macro: [{{"Ecto.Query", :from}, [2]}])
      state = %Recovery{rounds: 1, skip_ids: MapSet.new([2])}

      assert {:retry, %Plan{cause: {:line, _}, ids: ids}} =
               Recovery.next_round(attr, sites, state)

      assert ids == MapSet.new([1])
    end
  end

  describe "aborts" do
    test "when the attribution names nothing new" do
      state = %Recovery{rounds: 1, skip_ids: MapSet.new([1])}

      assert {:abort, :no_progress} =
               Recovery.next_round(attribution(line: [1]), [site(1)], state)

      assert {:abort, :no_progress} = Recovery.next_round(attribution([]), [site(1)], state)
    end

    test "once the budget is spent, whatever the attribution names" do
      state = %Recovery{rounds: Recovery.max_rounds()}
      assert {:abort, :exhausted} = Recovery.next_round(attribution(line: [1]), [site(1)], state)
    end
  end

  test "a newly blamed clean region justifies a round by itself, and is announced" do
    region = {"lib/a.ex", {1, 4}}

    assert {:retry, plan} =
             Recovery.next_round(attribution(clean: [region]), [site(1)], %Recovery{})

    assert plan.ids == MapSet.new()
    assert plan.regions == MapSet.new([region])

    assert [{:poison_round, %{dropped: [], clean: [%{file: "lib/a.ex", first: 1, last: 4}]}}] =
             Recovery.announcements(plan, [site(1)])
  end

  test "a clean first compile carries no summary" do
    assert Recovery.summary(%Recovery{}, []) == nil
  end

  # ── Properties ────────────────────────────────────────────────────────────────────────

  @files ["lib/a.ex", "lib/b.ex"]
  @regions [{"lib/a.ex", {1, 3}}, {"lib/b.ex", {4, 6}}]
  @macros [{"Ecto.Query", :from}, {"Ecto.Query", :where}]
  @block_keys for file <- @files, nid <- [0, 1], do: {file, {:dsl, nid}}

  defp subset(list) do
    let flags <- vector(length(list), boolean()) do
      MapSet.new(for {x, true} <- Enum.zip(list, flags), do: x)
    end
  end

  defp sites_gen do
    let specs <- list({oneof(@files), oneof([nil, {:dsl, 0}, {:dsl, 1}])}) do
      for {{file, block}, id} <- Enum.with_index(specs, 1), do: site(id, file: file, block: block)
    end
  end

  # One stray id beyond the sites: attribution may name an id no site carries.
  defp case_gen do
    let sites <- sites_gen() do
      ids = Enum.to_list(1..(length(sites) + 1))

      let [
        line <- subset(ids),
        macro <- list({oneof(@macros), subset(ids)}),
        clean <- subset(@regions),
        rounds <- integer(0, Recovery.max_rounds() + 2),
        skip_ids <- subset(ids),
        skip_regions <- subset(@regions),
        struck <- subset(@block_keys),
        escalated <- subset(@block_keys),
        macro_skips <- subset(@macros)
      ] do
        state = %Recovery{
          rounds: rounds,
          skip_ids: skip_ids,
          skip_regions: skip_regions,
          struck: struck,
          escalated: escalated,
          macro_skips: macro_skips
        }

        {sites, %{line: line, macro: macro, clean: clean}, state}
      end
    end
  end

  defp block_ids(sites), do: for(%Site{block_macro: b, id: id} <- sites, b != nil, do: id)

  defp key(%Site{block_macro: nil}), do: nil
  defp key(%Site{file: file, block_macro: tag}), do: {file, tag}

  property "dropped ids, regions, strikes, escalations, and macro skips only accumulate" do
    forall {sites, attr, state} <- case_gen() do
      case Recovery.next_round(attr, sites, state) do
        {:abort, _} ->
          true

        {:retry, %Plan{recovery: next}} ->
          next.rounds == state.rounds + 1 and
            Enum.all?(
              [:skip_ids, :skip_regions, :struck, :escalated, :macro_skips],
              &MapSet.subset?(Map.fetch!(state, &1), Map.fetch!(next, &1))
            )
      end
    end
  end

  property "every round drops something new, and the state records exactly that" do
    forall {sites, attr, state} <- case_gen() do
      case Recovery.next_round(attr, sites, state) do
        {:abort, _} ->
          true

        {:retry, %Plan{ids: ids, regions: regions, recovery: next}} ->
          MapSet.disjoint?(ids, state.skip_ids) and
            MapSet.disjoint?(regions, state.skip_regions) and
            not (Enum.empty?(ids) and Enum.empty?(regions)) and
            next.skip_ids == MapSet.union(state.skip_ids, ids) and
            next.skip_regions == MapSet.union(state.skip_regions, regions) and
            MapSet.subset?(regions, attr.clean)
      end
    end
  end

  property "every dropped id is one the attribution blamed or a twice-struck block holds" do
    forall {sites, attr, state} <- case_gen() do
      case Recovery.next_round(attr, sites, state) do
        {:abort, _} ->
          true

        {:retry, %Plan{cause: {:inline_macro, matched}, ids: ids, recovery: next}} ->
          blamed =
            Enum.reduce(attr.macro, MapSet.new(), fn {_, ids}, acc -> MapSet.union(acc, ids) end)

          MapSet.subset?(ids, blamed) and
            MapSet.disjoint?(ids, MapSet.new(block_ids(sites))) and
            next.struck == state.struck and
            Enum.all?(matched, fn {macro, _} -> MapSet.member?(next.macro_skips, macro) end)

        {:retry, %Plan{cause: {:line, escalated}, ids: ids}} ->
          escalated_ids = for s <- sites, MapSet.member?(escalated, key(s)), do: s.id

          MapSet.subset?(escalated, state.struck) and
            MapSet.subset?(ids, MapSet.union(attr.line, MapSet.new(escalated_ids)))
      end
    end
  end

  property "inline-macro attribution takes precedence whenever it names a new mutant" do
    forall {sites, attr, state} <- case_gen() do
      excluded = MapSet.union(state.skip_ids, MapSet.new(block_ids(sites)))

      fresh =
        Enum.reduce(attr.macro, MapSet.new(), fn {_, ids}, acc ->
          MapSet.union(acc, MapSet.difference(ids, excluded))
        end)

      case Recovery.next_round(attr, sites, state) do
        {:abort, :exhausted} -> true
        {:retry, %Plan{cause: {:inline_macro, _}, ids: ids}} -> ids == fresh
        _line_or_no_progress -> Enum.empty?(fresh)
      end
    end
  end

  property "a round is refused only for the budget or for want of anything new" do
    forall {sites, attr, state} <- case_gen() do
      new_line = MapSet.difference(attr.line, state.skip_ids)
      new_clean = MapSet.difference(attr.clean, state.skip_regions)

      case Recovery.next_round(attr, sites, state) do
        {:abort, :exhausted} -> state.rounds >= Recovery.max_rounds()
        {:abort, :no_progress} -> Enum.empty?(new_line) and Enum.empty?(new_clean)
        {:retry, _} -> state.rounds < Recovery.max_rounds()
      end
    end
  end

  property "a line round announces each dropped mutant once, individually or in its block" do
    forall {sites, attr, state} <- case_gen() do
      case Recovery.next_round(attr, sites, state) do
        {:retry, %Plan{cause: {:line, escalated}, ids: ids} = plan} ->
          [{:poison_round, %{dropped: dropped, escalated: blocks}}] =
            Recovery.announcements(plan, sites)

          individual = Enum.map(dropped, & &1.id)
          in_blocks = for s <- sites, MapSet.member?(escalated, key(s)), do: s.id
          site_ids = MapSet.new(sites, & &1.id)

          length(blocks) == MapSet.size(escalated) and
            MapSet.new(individual ++ Enum.filter(in_blocks, &MapSet.member?(ids, &1))) ==
              MapSet.intersection(ids, site_ids) and
            MapSet.disjoint?(MapSet.new(individual), MapSet.new(in_blocks))

        _ ->
          true
      end
    end
  end
end
