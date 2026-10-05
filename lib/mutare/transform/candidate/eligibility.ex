defmodule Mutare.Transform.Candidate.Eligibility do
  @moduledoc false

  # Which of a node's candidates exist for this run: `gate/2`. How a surviving candidate is
  # delivered and recorded is `Mutare.Transform.Candidate.Delivery`'s.

  alias Mutare.AST
  alias Mutare.Transform.{BindingFacts, Bindings, Candidate, Meta}
  alias Mutare.Transform.Candidate.Delivery

  @doc """
  Filter `node`'s candidates by mutator policy, drop duplicate return constants, and withhold
  a mutant whose source patch could not compile because it drops a binding a later read needs.

  Run *before* id assignment, so a dropped candidate leaves no id, selector, or site — it simply
  doesn't exist for this run (unlike a poisoned id, which is recorded). The analyzer records
  whether a candidate targets a call-option key (`call_option_key?`); the mutator
  defines the policy through `c:Mutare.Mutator.mutate_call_option_keys?/1`. Ids stay stable across a
  run's poison rebuilds because the mutator list — hence each spec's opts and policy — is constant
  within a run. Shared by emission (`Mutare.Transform`) and the collect walk
  (`Mutare.Transform.Analyze.Collect`), so the two can't disagree about which mutants exist.

  A `Candidate.Return` is redundant when a surviving `Candidate.InPlace` on this same node
  already replaces it with the same scalar constant. The site and its ignore matching use
  the node-level candidate, regardless of candidate order. Compare literal values strictly,
  ignoring their formatting metadata; other AST shapes are left alone. This uses actual
  candidates, so a disabled or opted-out family never suppresses another family's replacement.

  A whole-node replacement (`Candidate.InPlace`, `Candidate.Return`, or a whole-call mutation
  re-homed as a `Candidate.MacroPattern` branch running `mutant_expr`) that binds fewer names
  than `node` does — an argument dropped with the match inside it — is withheld when the
  dropped name is one this position cannot export as incoming — **fresh** (not bound on
  entry), or a **conflict** (an earlier sibling of the same expression writes it, and Elixir
  lets neither write out before the whole expression) — and something **reads it after**:
  patched into the source, that mutant would not compile, or delivered, its branch would name
  the wrong value (`Mutare.Transform.Bindings`). A dropped name nothing reads is simply
  unexported, and one bound on entry with no conflict is exported as the incoming value, so
  neither withholds. A structural pattern mutant keeps its node's bound set (thin mode) and
  the rest of the expression, so it never drops a name. A re-homed `MacroPattern` branch
  returns the selector's **fixed export tuple**, which names every variable of the pattern
  whether the source reads it after or not, so such a branch must also bind every name in
  that tuple the scope cannot supply as incoming — `x = 9` for `destructure([x, y], v)`
  leaves the tuple's `y` unbound even where nothing reads `y`, and is withheld: a valid
  source mutation, but one this delivery cannot carry.

  A name the node matches somewhere its route does not read as a value (`lazy(p = 8)`) is a
  write core cannot vouch for: exported, it may name the stale incoming value; unexported, it
  may be the write the source lets out. Where that name is in **conflict** — an earlier
  sibling writes it, so after the expression it is bound by that sibling, whether or not it
  was bound on entry — and read after, no delivery is faithful, so every candidate on the
  node is withheld. So it is where the name is **uncertain** — an earlier statement, or
  another position of the enclosing routed macro, may have bound it, and core could not
  read that effect in full (a match in a position its route reads as no value, a call whose
  route was withheld): exported as incoming it may name nothing, trapped it may hide the
  write the source lets out. And so is every candidate on a node whose own
  binding effect is **unknown**: a call inside a skipped argument whose route is a classifier
  core did not invoke there (`BindingFacts.unknown_routing?/1`) may bind names no reader reports,
  and a selector around it would trap them. The same classifier inside a `:raw` or `:hosted`
  position is not unknown: that region is syntax by its route's declaration, nothing in it
  is vouched for anyway, and its names are possible writes like any match written there.

  Run on the **source** node, before its children are emitted: `Mutare.Transform` gates on
  the way down its emit walk, so the facts read here — what the node binds, what it matches —
  are the program's, never a generated child selector's (whose export tuple binds a result
  temporary no source replacement could keep). Which candidates exist, and so which ids they
  claim, then depends on the source alone, not on which other mutants are ignored,
  poison-skipped or focused away by `emit_ids` — the count and render passes agree.
  """
  @spec gate([Delivery.node_candidate()], Macro.t()) :: [Delivery.node_candidate()]
  def gate([], _node), do: []

  def gate(candidates, node) do
    candidates
    |> filter_policy()
    |> drop_duplicate_returns()
    |> drop_binding_drops(node)
  end

  defp drop_binding_drops(candidates, node) do
    scope = Meta.bindings(node)
    {_bound, conflicts, uncertain, _later} = scope
    escaping = BindingFacts.expression_bindings(node)
    read? = &Bindings.read_after?(scope, &1)
    exportable? = &Bindings.incoming?(scope, &1)

    # Exported as incoming, the name may be stale (a conflict) or unbound (uncertain);
    # trapped, it may be the write the source lets out.
    unvouchable? = fn name ->
      MapSet.member?(conflicts, name) or MapSet.member?(uncertain, name)
    end

    unvouched =
      node
      |> BindingFacts.matched_names()
      |> Enum.reject(&(&1 in escaping))
      |> Enum.filter(&(unvouchable?.(&1) and read?.(&1)))

    needed = Enum.filter(escaping, &(read?.(&1) and not exportable?.(&1)))

    if unvouched != [] or BindingFacts.unknown_routing?(node),
      do: [],
      else: Enum.reject(candidates, &drops_binding?(&1, needed, exportable?))
  end

  defp drops_binding?(%kind{} = candidate, needed, _exportable?)
       when kind in [Candidate.InPlace, Candidate.Return] do
    candidate |> Delivery.selector_branch() |> drops_any?(needed)
  end

  defp drops_binding?(
         %Candidate.MacroPattern{mutant_expr: branch, export: export},
         needed,
         exportable?
       ) do
    required = export |> BindingFacts.referenced_names() |> Enum.reject(exportable?)
    drops_any?(branch, Enum.uniq(needed ++ required))
  end

  defp drops_binding?(_candidate, _needed, _exportable?), do: false

  defp drops_any?(_branch, []), do: false

  defp drops_any?(branch, needed) do
    kept = BindingFacts.expression_bindings(branch)
    Enum.any?(needed, &(&1 not in kept))
  end

  defp filter_policy(candidates) do
    Enum.reject(candidates, fn
      %Candidate.InPlace{call_option_key?: true, mutator: spec} ->
        not Mutare.Mutator.Dispatch.mutate_call_option_keys?(spec)

      _candidate ->
        false
    end)
  end

  # Runs on every node of every file, and all but a handful carry no `Candidate.Return` (most
  # carry no candidates at all), so look for one before building the constant set.
  defp drop_duplicate_returns(candidates) do
    if Enum.any?(candidates, &match?(%Candidate.Return{}, &1)),
      do: reject_covered_returns(candidates),
      else: candidates
  end

  defp reject_covered_returns(candidates) do
    constants =
      for %Candidate.InPlace{mutated: mutated} <- candidates,
          {:ok, value} <- [AST.literal_value(mutated)],
          into: MapSet.new(),
          do: value

    Enum.reject(candidates, fn
      %Candidate.Return{mutated: mutated} ->
        case AST.literal_value(mutated) do
          {:ok, value} -> MapSet.member?(constants, value)
          :error -> false
        end

      _candidate ->
        false
    end)
  end
end
