defmodule Mutare.Transform.Analyze.Collect do
  @moduledoc false

  # The **collect mode** of the analyze pass, behind the public
  # `Mutare.Analyze.expression_mutations/3`: the logical single-point mutants of one expression
  # subtree, as data — each returned as a rebuild of the whole subtree with exactly one position
  # swapped. Built for the selector-host sub-contract (a host handing an Elixir island inside its
  # DSL fragment — an Ecto pin interior — back to core's families for *generation*, while keeping
  # *delivery* 100% host-owned through its own weave).
  #
  # **The walk is not duplicated** — that is the load-bearing design decision. Collect runs the
  # very same `Mutare.Transform.Analyze.annotate/2` descent the transform runs (so macro-routing
  # stamps, pattern positions, sigil/bitstring/quote special cases, equivalent-sibling
  # suppression, and every future shape rule apply identically and cannot drift), then *reads the
  # annotations back* instead of emitting selectors:
  #
  #   1. filter the specs to **node-level producers** (`mutate/1`/`mutate/2` exporters, hosts
  #      excluded — see below),
  #   2. `annotate/2` the subtree and run the same pre-emission passes emission would
  #      (`Overlap.resolve/1`; the call-option-key gate via `Candidate.Delivery.gate/1`),
  #   3. walk the annotated tree post-order (mirroring emission's id order), collecting each
  #      surviving `Candidate.InPlace` together with the index path to its host node while
  #      stripping the delivery metadata,
  #   4. rebuild the whole (stripped) subtree once per candidate, substituting the candidate's
  #      `mutated` node at its path.
  #
  # What deliberately does **not** come back:
  #
  #   * **Structural candidates** — def-level, clause-level, and return-value shapes don't apply
  #     to a bare expression subtree. Only `Candidate.InPlace` is collected; the clause-delivery
  #     kinds (`CaseClause`/`CasePattern`/`MatchPattern`/`MacroPattern`/`RescueDrop`) and the
  #     structural-only families that produce them are dropped. Spec filtering to
  #     `mutate/1`/`mutate/2` exporters removes the structural-only families up front (which also
  #     keeps the `if`-condition hoist inert — it is gated on `Mutare.Mutators.IfCondition` being
  #     present — so no hoist placeholder ever reaches a rebuild).
  #   * **Hosts** — a spec whose module exports `host/2` is excluded even when it also exports
  #     `mutate/1`: a nested `{:hosted, …}` stamp inside the subtree stays raw either way (the
  #     routing leaves the argument untouched), and excluding the host specs keeps its `host/2`
  #     from even being probed. No recursive hosting; the outer host owns the region.
  #   * **Ids, sites, coverage, emission** — collect is pure. The host folds the rebuilds into
  #     its Target `:mutants` (tagging each with its `producer` spec), and the ordinary hosted
  #     pipeline claims ids and records Sites when the Target flows through `HostedEmit`.
  #
  # Two knowingly-accepted fidelity notes, both cosmetic-only (the rebuild is always
  # compile-equivalent): a bitstring construction's binary-valued literal segments come back
  # `::binary`-pinned (the annotate walk pins them unconditionally), and candidates the analyze
  # pass pruned for selector-specific reasons (escaping-binding ancestors) stay pruned — collect
  # never *out-mutates* what core itself would deliver on the same code, which is the contract.

  alias Mutare.Mutator.{Dispatch, Mutation, Spec}
  alias Mutare.Transform.{Candidate, Meta, Overlap}
  alias Mutare.Transform.Analyze
  alias Mutare.Transform.Candidate.Delivery

  # `context` is accepted for call-site symmetry with the mutator callbacks (`map()`, not
  # `Mutare.Mutator.context()`, so the bare default doesn't have to fake a `:pipe_mode`).
  @spec expression_mutations(Macro.t(), [Spec.t() | module()], map()) ::
          [{Spec.t(), Macro.t(), String.t() | nil, Mutation.variant()}]
  def expression_mutations(subtree, mutators, _context \\ %{}) do
    case node_level_specs(mutators) do
      [] ->
        []

      specs ->
        annotated = subtree |> Analyze.annotate(specs) |> Overlap.resolve()
        {stripped, collected} = walk(annotated, [], [])

        for {rev_path, cand} <- collected do
          mutated_tree = replace_at(stripped, Enum.reverse(rev_path), cand.mutated)
          {cand.mutator, mutated_tree, cand.note, resolved_variant(cand)}
        end
    end
  end

  # The specs whose node-level producers run: `mutate/1`/`mutate/2` exporters, minus selector
  # hosts (see the moduledoc). Structural-only families (ReturnValue, IfCondition, the pattern
  # families) fall out of the first filter; a host falls out of the second even when it also
  # exports `mutate/1`.
  defp node_level_specs(mutators) do
    specs =
      mutators
      |> Enum.map(&Spec.coerce/1)
      |> Dispatch.implementing_any(:mutate, [1, 2])

    hosts = Dispatch.implementing(specs, :host, 2)
    Enum.reject(specs, &(&1 in hosts))
  end

  # --- collect: post-order walk, stripping delivery meta ----------------------

  # Walk the annotated subtree post-order (children before the node's own candidates, mirroring
  # emission's post-order id assignment), returning `{stripped_tree, [{rev_path, candidate}]}`.
  # `rev_path` is the reversed index path from the subtree root to the candidate's host node
  # (`0` = a 3-tuple's form / a pair's left, `i` = a 3-tuple's argument `i-1` / a list element /
  # a pair's right at `1`); `replace_at/3` follows the same convention.
  defp walk({_form, _meta, _args} = node, rev_path, acc) do
    {candidates, node} = Meta.take_candidates(node, :in_place)
    {form, meta, args} = Meta.strip_delivery(node)

    {form, acc} = walk(form, [0 | rev_path], acc)

    {args, acc} =
      if is_list(args) do
        walk_each(args, 1, rev_path, acc)
      else
        {args, acc}
      end

    own =
      candidates
      |> Enum.filter(&match?(%Candidate.InPlace{}, &1))
      |> Delivery.gate()
      |> Enum.map(&{rev_path, &1})

    {{form, meta, args}, acc ++ own}
  end

  defp walk({left, right}, rev_path, acc) do
    {left, acc} = walk(left, [0 | rev_path], acc)
    {right, acc} = walk(right, [1 | rev_path], acc)
    {{left, right}, acc}
  end

  defp walk(list, rev_path, acc) when is_list(list), do: walk_each(list, 0, rev_path, acc)

  defp walk(other, _rev_path, acc), do: {other, acc}

  defp walk_each(children, first_index, rev_path, acc) do
    {children, {acc, _index}} =
      Enum.map_reduce(children, {acc, first_index}, fn child, {acc, index} ->
        {child, acc} = walk(child, [index | rev_path], acc)
        {child, {acc, index + 1}}
      end)

    {children, acc}
  end

  # --- rebuild: substitute one node by index path ------------------------------

  defp replace_at(_node, [], replacement), do: replacement

  defp replace_at({form, meta, args}, [0 | rest], replacement),
    do: {replace_at(form, rest, replacement), meta, args}

  defp replace_at({form, meta, args}, [index | rest], replacement) when is_list(args),
    do: {form, meta, List.update_at(args, index - 1, &replace_at(&1, rest, replacement))}

  defp replace_at({left, right}, [0 | rest], replacement),
    do: {replace_at(left, rest, replacement), right}

  defp replace_at({left, right}, [1 | rest], replacement),
    do: {left, replace_at(right, rest, replacement)}

  defp replace_at(list, [index | rest], replacement) when is_list(list),
    do: List.update_at(list, index, &replace_at(&1, rest, replacement))

  # The mutant's variant label(s), resolved *now* at the node level — the same
  # `Dispatch.variant/4` call `Mutare.Site` makes (production-time tag first, else the family's
  # `variant/2` derivation over the `{original, mutated}` node pair). Resolving here matters:
  # once the host wraps the rebuild under its pin, the fragment-level pair no longer has the
  # shape an operator family's `variant/2` derives from, so a Site-time derivation would come up
  # empty. The resolved list rides the host's `%Mutation{}` as a carried tag, which Site-side
  # `Dispatch.variant/4` takes verbatim. `nil` when the family declares no label for this mutant.
  defp resolved_variant(%Candidate.InPlace{} = cand) do
    case Dispatch.variant(cand.mutator, cand.original, cand.mutated, cand.variant) do
      [] -> nil
      labels -> labels
    end
  end
end
