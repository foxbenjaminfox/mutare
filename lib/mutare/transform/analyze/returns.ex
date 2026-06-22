defmodule Mutare.Transform.Analyze.Returns do
  @moduledoc false

  # Return-value mutation: attach return-value candidates to the *tail
  # expression(s)* of a `def`/`defp` clause's return-path blocks. Split out of
  # `Mutare.Transform.Analyze` — it is a self-contained candidate-builder the main
  # walk calls once per clause (`annotate_returns/3`), and it never recurses back
  # into the descent (no `analyze/3`/`offer`/`recurse`), so the dependency is
  # strictly one-way (Analyze → Returns).

  alias Mutare.AST
  alias Mutare.Mutator
  alias Mutare.Transform.{Candidate, NodeRange}

  # The try-style body blocks whose clause bodies are *return paths*
  # (`rescue`/`catch`/`else`). Their left side is always a match, and their tails
  # return — unlike `:after`, whose value `try` discards. The canonical set is
  # also used for clause-block routing in `Mutare.Transform.Analyze` (which owns
  # it); these atoms are fixed Elixir semantics, so the return logic classifies
  # keys independently here rather than reaching back into the parent.
  @clause_block_keys [:rescue, :catch, :else]

  # Attach return-value candidates to the *tail expression(s)* of the clause's
  # return-path blocks — the positions a `def`/`defp` clause returns from. This is
  # structural (a tail is a position no node-level mutator can match), so it runs
  # only when some enabled mutator implements `return_replacements/1` (the built-in
  # `Mutare.Mutators.ReturnValue`, or a custom one). The `:do` block
  # returns from its body tail; a `rescue`/`catch`/`else` block returns from
  # *every* clause body's tail (a rescued/caught error or an `else` match is a
  # return path too). `:after` is excluded — `try` discards its value.
  #
  # `analyzed_kw` carries the already-attached operator candidates; `raw_kw` is the
  # pre-analysis copy, used only to build each candidate's clean `original`/`range`
  # (so the diff renders the author's tail, un-annotated). The two are structurally
  # identical — analysis only adds metadata — so `map_tail/3` can navigate them in
  # lockstep to the same tail node. `ReturnValue.replacements/1` decides the
  # constant(s) (or that the tail is ineligible).
  def annotate_returns(analyzed_kw, raw_kw, mutators) do
    case Mutator.implementing_any(mutators, :return_replacements, [1, 2]) do
      [] ->
        analyzed_kw

      return_mutators ->
        [analyzed_kw, raw_kw]
        |> Enum.zip()
        |> Enum.map(fn {{key, analyzed_value}, {_key, raw_value}} ->
          {key, annotate_block_returns(key, analyzed_value, raw_value, return_mutators)}
        end)
    end
  end

  # Route one body block to its return path(s): the `:do` body tail, each
  # `rescue`/`catch`/`else` clause body tail, or — for `:after` (value discarded)
  # and any other key — nothing.
  defp annotate_block_returns(key, analyzed, raw, return_mutators) do
    cond do
      do_key?(key) -> attach_return(analyzed, raw, return_mutators)
      # NOTE (equivalent survivor, deliberately not `# mutare:ignore`d so the killed
      # `-> false` sibling stays counted): forcing this `cond` clause to `true` is
      # equivalent — the only non-`:do`, non-clause-block key reaching here is `:after`,
      # whose value is an expression (not a clause list), so `attach_clause_returns/3`
      # no-ops on it exactly like the `true -> analyzed` arm would.
      clause_block_key?(key) -> attach_clause_returns(analyzed, raw, return_mutators)
      true -> analyzed
    end
  end

  # rescue/catch/else: a list of `->` clauses; each clause body's tail is a return
  # path. Walk the analyzed and raw clause lists in lockstep (structurally
  # identical) and append a return candidate to each clause body's tail.
  # NOTE (equivalent survivors, deliberately not `# mutare:ignore`d so the killed
  # `-> false` siblings stay counted): the `is_list/1` and `length/1` checks in this guard
  # are a defensive assertion that always holds — `analyzed_clauses` is `raw_clauses` with
  # only metadata added, so the two are always equal-length lists. Loosening the guard
  # (forcing it `true`, weakening `and` to `or`) is therefore equivalent; forcing it `false`
  # is killed (rescue/catch/else returns vanish).
  defp attach_clause_returns(analyzed_clauses, raw_clauses, return_mutators)
       when is_list(analyzed_clauses) and is_list(raw_clauses) and
              length(analyzed_clauses) == length(raw_clauses) do
    [analyzed_clauses, raw_clauses]
    |> Enum.zip()
    |> Enum.map(fn {analyzed, raw} -> attach_clause_return(analyzed, raw, return_mutators) end)
  end

  # mutare:ignore[clause_drop] equivalent — the guard above always holds for a real block (analyzed is raw + metadata, equal-length lists), so this fallback is unreachable for valid input.
  defp attach_clause_returns(analyzed_clauses, _raw, _return_mutators), do: analyzed_clauses

  defp attach_clause_return(
         {:->, meta, [patterns, analyzed_body]},
         {:->, _rmeta, [_raw_patterns, raw_body]},
         return_mutators
       ) do
    {:->, meta, [patterns, attach_return(analyzed_body, raw_body, return_mutators)]}
  end

  # mutare:ignore[clause_drop] equivalent — every rescue/catch/else clause is a `{:->, _, [patterns, body]}` node, so the head above always matches and this fallback is unreachable for valid input.
  defp attach_clause_return(analyzed, _raw, _return_mutators), do: analyzed

  defp do_key?(key), do: AST.key_atom(key) == :do

  # NOTE (equivalent survivor, deliberately not `# mutare:ignore`d so the killed
  # `-> false` sibling stays counted): forcing this to `true` is equivalent — only `:after`
  # reaches the second `cond` arm with this `true`, and its expression value makes
  # `attach_clause_returns/3` no-op anyway (see `annotate_block_returns/4`).
  defp clause_block_key?(key), do: AST.key_atom(key) in @clause_block_keys

  # Find the tail expression of a `:do` block (the last statement of a multi-
  # statement block, else the whole single-expression value) and append a
  # return-value candidate per `{spec, replacement}` (each return mutator's
  # `return_replacements/1` output, tagged with its spec). The candidates ride in
  # the tail node's own `meta[:mutare]` — *after* any operator candidates already
  # there — so emission builds one selector `case` hosting both an operator swap
  # and the return constant on the same node, ids in attachment order.
  defp attach_return(analyzed_value, raw_value, return_mutators) do
    map_tail(analyzed_value, raw_value, fn analyzed_tail, raw_tail ->
      replacements =
        Enum.flat_map(return_mutators, fn spec ->
          Enum.map(Mutator.return_replacements(spec, raw_tail), &{spec, &1})
        end)

      case replacements do
        [] -> analyzed_tail
        _ -> append_return_candidates(analyzed_tail, raw_tail, replacements)
      end
    end)
  end

  # Apply `fun` to the tail of a (possibly block) value, in lockstep on the
  # analyzed and raw copies. A statement sequence (`>= 2` statements) returns the
  # body with its last statement mapped; anything else is itself the tail. A
  # single-statement `:__block__` (a Sourceror-wrapped literal like `{:__block__,
  # _, [:ok]}`) is intentionally *not* unwrapped — the wrapping block is the node
  # we attach to.
  # NOTE (equivalent survivor, deliberately not `# mutare:ignore`d so the killed
  # `-> false` sibling stays counted): `length(a_stmts) == length(r_stmts)` is a defensive
  # assertion that always holds (analyzed and raw are the same block with only metadata
  # added), so forcing it `true` is equivalent; forcing it `false` is killed.
  defp map_tail({:__block__, meta, a_stmts}, {:__block__, _rmeta, r_stmts}, fun)
       when length(a_stmts) >= 2 and length(a_stmts) == length(r_stmts) do
    {a_init, [a_last]} = Enum.split(a_stmts, -1)
    {_r_init, [r_last]} = Enum.split(r_stmts, -1)
    {:__block__, meta, a_init ++ [fun.(a_last, r_last)]}
  end

  defp map_tail(analyzed_value, raw_value, fun), do: fun.(analyzed_value, raw_value)

  # Append a `Candidate.Return` per replacement to the tail node's metadata,
  # preserving any operator candidates already there (so operator ids precede the
  # return id at a shared node). The candidate's `original`/`range` come from the
  # *raw* tail, so the diff is clean. A tail we can't annotate (a non-`{f,m,a}`
  # node, or one Sourceror can't range) gets no return mutant.
  # mutare:ignore[guard_drop] equivalent — a `{form, meta, args}` AST node always carries keyword-list meta, so the guard never excludes a real tail; it only fences out a malformed 3-tuple that can't occur here.
  defp append_return_candidates({form, meta, args} = node, raw_tail, replacements)
       when is_list(meta) do
    case NodeRange.get(raw_tail) do
      %{} = range ->
        candidates =
          Enum.map(replacements, fn {spec, replacement} ->
            %Candidate.Return{
              mutator: spec,
              original: raw_tail,
              mutated: replacement,
              range: range
            }
          end)

        existing = Keyword.get(meta, :mutare, [])
        {form, Keyword.put(meta, :mutare, existing ++ candidates), args}

      _ ->
        node
    end
  end

  # mutare:ignore[clause_drop] equivalent — Sourceror wraps every scalar/tuple/list literal tail in a `:__block__` 3-tuple, so the head above matches every tail that has replacements; this fallback is unreachable for valid input.
  defp append_return_candidates(node, _raw_tail, _replacements), do: node
end
