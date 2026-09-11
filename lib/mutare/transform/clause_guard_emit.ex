defmodule Mutare.Transform.ClauseGuardEmit do
  @moduledoc false

  # Guard-sequence delivery of `Candidate.ClauseGuard`s: guard-only mutants of the clauses no
  # other path reaches — a `with`/`for` `<-` clause, a `with`/`try` `else` clause, a `try`
  # `catch` clause, a `for … reduce:` `do` clause. None can host an extra clause (a `<-` has no
  # clause list, and a `with` non-match must hand the *original* value to `else`, so the subject
  # can't be tupled the way `CaseClauseEmit` does), but a guard-only mutant needs none: its
  # pattern is the original's. So the clause's guard becomes a guard *sequence*,
  #
  #     pattern when <var> === <id₁> and <g₁> when … when <var> ∉ ids and <g>
  #
  # every alternative gated the way lifted heads and interleaved clauses are (`GuardBuild`).
  # Each `when` alternative is tried on its own and a failing one — a raising one included —
  # fails only itself, while `andalso` short-circuits on the gate before an inactive mutant's
  # guard is evaluated: with mutant `idᵢ` active the clause behaves exactly as if its guard read
  # `<gᵢ>`, with none active exactly as written. Bodies are untouched.
  #
  # Coverage is recorded once, for every live id, in a block before the construct — reaching the
  # construct is the guards' coverage, as it is for a `case`'s later clauses. The gate reads the
  # hoisted selector variable (nothing guard-safe can read `:persistent_term`), so where that
  # binding is not in scope (module level, a default-argument position, a nested module's `def`)
  # the guard candidates are **not claimed** at all: there is no whole-construct fallback,
  # because the clauses' bindings escape. Unclaimed, they take no id and leave no site, like any
  # position never offered. Any other candidate on the node (a return-value tail, a whole-node
  # offer) keeps its ordinary selector, wrapped around the rewritten construct.

  alias Mutare.AST
  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.{Candidate, Ctx, GuardBuild, ImportWitness, Meta, Scope, SelectorEmit}
  alias Mutare.Transform.Candidate.Delivery

  @spec emit(Macro.t(), [Delivery.node_candidate()], Ctx.t()) :: {Macro.t(), Ctx.t()}
  def emit(node, candidates, ctx) do
    candidates =
      if deliverable?(ctx), do: candidates, else: Enum.reject(candidates, &clause_guard?/1)

    {claimed, ctx} =
      SelectorEmit.claim_items(candidates, ctx, {&Delivery.site/4, &Delivery.line/1}, fn id, c ->
        {id, c}
      end)

    {guards, whole} = Enum.split_with(claimed, fn {_id, c} -> clause_guard?(c) end)
    default = deliver(Meta.strip_delivery(node), guards, ctx)
    {select(default, whole, ctx), ctx}
  end

  defp deliverable?(%Ctx{scope: %Scope{active_bound: true, module_depth: 0}}), do: true
  defp deliverable?(_ctx), do: false

  defp clause_guard?(%Candidate.ClauseGuard{}), do: true
  defp clause_guard?(_candidate), do: false

  defp deliver(node, [], _ctx), do: node

  defp deliver(node, guards, ctx) do
    var = ctx.config.active_var

    rewritten =
      guards
      |> Enum.group_by(fn {_id, c} -> c.locator end)
      |> Enum.reduce(node, fn {locator, variants}, acc -> rewrite(acc, locator, variants, var) end)

    ids = Enum.map(guards, &elem(&1, 0))
    {:__block__, [], [Recorder.record_ast(ids, var, ctx.config.runtime_namespace), rewritten]}
  end

  defp select(node, [], _ctx), do: node

  defp select(node, whole, ctx) do
    branches =
      Enum.map(whole, fn {id, c} ->
        branch = Delivery.selector_branch(c) |> ImportWitness.wrap(ImportWitness.for_candidate(c))
        {:->, [], [[id], branch]}
      end)

    SelectorEmit.selector_case(node, branches, ctx)
  end

  # `{:clause, i}`: the i-th leading argument of a `with`/`for` — a `<-` clause / qualifier.
  defp rewrite({form, meta, args}, {:clause, i}, variants, var) do
    {form, meta, List.update_at(args, i, &rewrite_generator(&1, variants, var))}
  end

  # `{:else | :catch | :do, i}`: the i-th arrow clause of that block of the trailing keyword.
  defp rewrite({form, meta, args}, {key, i}, variants, var) do
    {leading, [blocks]} = Enum.split(args, -1)

    blocks =
      Enum.map(blocks, fn {k, v} ->
        if AST.key_atom(k) == key,
          do: {k, update_clause(v, i, &rewrite_arrow(&1, variants, var))},
          else: {k, v}
      end)

    {form, meta, leading ++ [blocks]}
  end

  # A `for … reduce:` `do` block keeps Sourceror's list-literal wrapping; the others are bare.
  defp update_clause({:__block__, meta, [clauses]}, i, fun) when is_list(clauses),
    do: {:__block__, meta, [List.update_at(clauses, i, fun)]}

  defp update_clause(clauses, i, fun) when is_list(clauses), do: List.update_at(clauses, i, fun)

  defp rewrite_generator({:<-, meta, [head, rhs]}, variants, var),
    do: {:<-, meta, [rewrite_head(head, variants, var), rhs]}

  defp rewrite_arrow({:->, meta, [[head], body]}, variants, var),
    do: {:->, meta, [[rewrite_head(head, variants, var)], body]}

  defp rewrite_head({:when, wm, when_args}, variants, var) do
    {patterns, [guard]} = Enum.split(when_args, -1)
    {:when, wm, patterns ++ [guard_sequence(guard, variants, var)]}
  end

  # The mutant alternatives in id order, then the original gated by the exclusion of exactly
  # those ids — right-nested, the shape the parser gives `a when b when c`. A `GuardDrop`'s
  # `nil` mutant guard leaves the bare gate; an original that is itself a sequence stays one
  # (`and_into` distributes the exclusion over its alternatives).
  defp guard_sequence(guard, variants, var) do
    ids = Enum.map(variants, &elem(&1, 0))

    mutants =
      Enum.map(variants, fn {id, c} ->
        GuardBuild.and_into(GuardBuild.gate(id, var), c.mutant_guard)
      end)

    original = GuardBuild.merge(GuardBuild.exclusion(ids, var), guard)

    (mutants ++ [original])
    |> Enum.reverse()
    |> Enum.reduce(fn alt, acc -> {:when, [], [alt, acc]} end)
  end
end
