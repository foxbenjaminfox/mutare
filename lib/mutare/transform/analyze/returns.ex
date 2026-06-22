defmodule Mutare.Transform.Analyze.Returns do
  @moduledoc false

  # Return-value mutation: attach return-value candidates to the *leaf return
  # tails* of a `def`/`defp` clause's return-path blocks. A clause returns from its
  # `:do` body tail and each `rescue`/`catch`/`else` clause body tail; and when a
  # tail is itself a `case`/`cond`/`if`/`unless`/`with`/`try`/`receive`, the tail
  # position propagates into each branch body, so every branch's leaf tail is a
  # return path too (`map_return_tails/3` + `@return_blocks`). The def-level
  # `rescue`/`catch`/`else` blocks and a `try` *expression*'s clause blocks share
  # one clause walk (`map_clauses/3`). Split out of `Mutare.Transform.Analyze` — it is a
  # self-contained candidate-builder the main walk calls once per clause
  # (`annotate_returns/3`), and it never recurses back into the descent (no
  # `analyze/3`/`offer`/`recurse`), so the dependency is strictly one-way
  # (Analyze → Returns).

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

  # The control-flow forms whose branch bodies are return paths when the form is in
  # tail position, and the kind of each return-path block key: `:value` is a single
  # tail expression (an `if`/`with`/`try` `:do`, an `if` `:else`); `:clauses` is a
  # `->` clause list whose *every* body tail is a path (a `case`/`receive` `:do`, a
  # `try`/`with` clause block). A key absent from a form's map is **not** a return
  # path — most pointedly `try`'s `:after` (whose value `try` discards) is omitted,
  # while `receive`'s `:after` (the body run when the timeout fires *is* the
  # construct's value) is present. In every one of these forms the keyword-block
  # list is the **last** argument — the `case` scrutinee, the `if` condition, the
  # `with` qualifiers all precede it — so the walk splits it off the end uniformly.
  @return_blocks %{
    case: %{do: :clauses},
    cond: %{do: :clauses},
    if: %{do: :value, else: :value},
    unless: %{do: :value, else: :value},
    with: %{do: :value, else: :clauses},
    try: %{do: :value, rescue: :clauses, catch: :clauses, else: :clauses},
    receive: %{do: :clauses, after: :clauses}
  }

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
  # identical — analysis only adds metadata — so `map_return_tails/3` can navigate
  # them in lockstep to the same tail node(s). `ReturnValue.replacements/1` decides
  # the constant(s) (or that the tail is ineligible).
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

  # Route one `def`/`defp` body block to its return path(s): the `:do` body tail,
  # or each `rescue`/`catch`/`else` clause body tail. A `def … rescue/catch/else …`
  # is an implicit `try`, so its clause blocks are mapped by the very same
  # `map_clauses/3` the `try` *expression* uses (`map_return_tails/3` below) — one
  # walk, not two. `:after` (and any other key) returns nothing: `try` discards its
  # value, and its expression payload isn't a clause list so it falls through here.
  defp annotate_block_returns(key, analyzed, raw, return_mutators) do
    cond do
      do_key?(key) ->
        attach_return(analyzed, raw, return_mutators)

      clause_block_key?(key) and clause_list?(analyzed) and clause_list?(raw) and
          length(analyzed) == length(raw) ->
        map_clauses(analyzed, raw, leaf_attacher(return_mutators))

      true ->
        analyzed
    end
  end

  defp do_key?(key), do: AST.key_atom(key) == :do

  defp clause_block_key?(key), do: AST.key_atom(key) in @clause_block_keys

  # The leaf step shared by every path: offer the tail to each return mutator and
  # append a `Candidate.Return` per `{spec, replacement}` (the mutator's
  # `return_replacements/1` output, tagged with its spec). The candidates ride in
  # the tail node's own `meta[:mutare]` — *after* any operator candidates already
  # there — so emission builds one selector `case` hosting both an operator swap
  # and the return constant on the same node, ids in attachment order.
  defp leaf_attacher(return_mutators) do
    fn analyzed_tail, raw_tail ->
      replacements =
        Enum.flat_map(return_mutators, fn spec ->
          Enum.map(Mutator.return_replacements(spec, raw_tail), &{spec, &1})
        end)

      case replacements do
        [] -> analyzed_tail
        _ -> append_return_candidates(analyzed_tail, raw_tail, replacements)
      end
    end
  end

  # Find every *leaf return tail* reachable from a `:do` block — the last statement
  # of a multi-statement block, and (transitively) each branch body of a
  # `case`/`cond`/`if`/`unless`/`with`/`try`/`receive` in tail position — and attach
  # the return candidates there.
  defp attach_return(analyzed_value, raw_value, return_mutators) do
    map_return_tails(analyzed_value, raw_value, leaf_attacher(return_mutators))
  end

  # Apply `fun` at every *leaf return tail* of a (possibly control-flow) value, in
  # lockstep on the analyzed and raw copies. The generalization of the old
  # single-tail `map_tail`: a `case`/`cond`/`if`/`unless`/`with`/`try`/`receive` in
  # tail position propagates the tail position into each of its branch bodies (each
  # is a return path), so `fun` is applied to every branch's leaf tail rather than
  # to the construct as a whole. Everything outside this control-flow *whitelist*
  # (`@return_blocks`) is itself a leaf — the prior behaviour — so an unknown block
  # macro / call / literal is handled exactly as before, and a single-statement
  # `:__block__` (a Sourceror-wrapped literal like `{:__block__, _, [:ok]}`) is
  # intentionally *not* unwrapped (the wrapping block is the node we attach to). The
  # two trees are structurally identical (analysis only adds metadata), so any
  # structural surprise falls through to the leaf clause, where the whole node is
  # the tail.
  #
  # Tail position is transitive *and* self-limiting: a multi-statement block only
  # descends its **last** statement, so a `case` that is not itself in tail
  # position (bound to a variable, a non-final statement) is never reached and its
  # branches are correctly not return paths.

  # A statement sequence: the tail is the last statement — recurse into it.
  # NOTE (equivalent survivor, deliberately not `# mutare:ignore`d so the killed
  # `-> false` sibling stays counted): `length(a_stmts) == length(r_stmts)` is a defensive
  # assertion that always holds (analyzed and raw are the same block with only metadata
  # added), so forcing it `true` is equivalent; forcing it `false` is killed.
  defp map_return_tails({:__block__, meta, a_stmts}, {:__block__, _rmeta, r_stmts}, fun)
       when length(a_stmts) >= 2 and length(a_stmts) == length(r_stmts) do
    {a_init, [a_last]} = Enum.split(a_stmts, -1)
    {_r_init, [r_last]} = Enum.split(r_stmts, -1)
    {:__block__, meta, a_init ++ [map_return_tails(a_last, r_last, fun)]}
  end

  # A control-flow construct: route each of its keyword blocks by `@return_blocks`.
  # The block list is always the *last* argument (the `case` scrutinee / `if`
  # condition / `with` qualifiers precede it), so split it off, map it, and rebuild.
  # A non-descendable shape (the last arg isn't a block list, or a `:clauses` block
  # isn't in canonical block form — see `descendable_blocks?/3`) falls through to
  # the leaf clause: the whole construct is then the tail, as before this descent.
  defp map_return_tails({form, meta, a_args} = analyzed, {form, _rmeta, r_args} = raw, fun)
       when is_map_key(@return_blocks, form) and is_list(a_args) and is_list(r_args) and
              a_args != [] and length(a_args) == length(r_args) do
    {a_head, [a_blocks]} = Enum.split(a_args, -1)
    {_r_head, [r_blocks]} = Enum.split(r_args, -1)
    kinds = Map.fetch!(@return_blocks, form)

    if descendable_blocks?(a_blocks, r_blocks, kinds) do
      {form, meta, a_head ++ [map_kw_blocks(a_blocks, r_blocks, kinds, fun)]}
    else
      fun.(analyzed, raw)
    end
  end

  # Leaf: any node outside the control-flow whitelist is itself the tail.
  defp map_return_tails(analyzed_value, raw_value, fun), do: fun.(analyzed_value, raw_value)

  # Whether a construct's block list is safe to descend. It must be a keyword-block
  # list (both copies, equal length) whose every `:clauses` block carries a clean
  # `->` clause list. The **keyword form** (`with …, else: (c -> …)`, `case x, do:
  # (… -> …)`) wraps that clause list in an extra `:__block__`; descending a
  # *sibling* block (e.g. the `:do` value) would force Sourceror to re-render the
  # whole construct in block form, where the wrapper renders as an illegal `[ -> ]`
  # list. So a non-canonical construct is left a leaf (mutated whole — which renders
  # fine), exactly as it was before `with`/`try`/`receive` descent. (`:value`
  # blocks are always fine; an `if x, do: a, else: b` keyword form has no clauses.)
  defp descendable_blocks?(a_blocks, r_blocks, kinds) do
    kw_block_list?(a_blocks) and kw_block_list?(r_blocks) and
      length(a_blocks) == length(r_blocks) and
      Enum.all?(Enum.zip(a_blocks, r_blocks), fn {{a_key, a_payload}, {_r_key, r_payload}} ->
        case Map.get(kinds, AST.key_atom(a_key)) do
          :clauses -> clause_list?(a_payload) and clause_list?(r_payload)
          _ -> true
        end
      end)
  end

  # Map a keyword-block list `[{key, payload}]` by a `%{key => :value | :clauses}`
  # spec: a `:value` payload is recursed as a single tail; a `:clauses` payload has
  # each `->` clause body recursed; a key absent from the spec (a discarded `try`
  # `:after`) passes through untouched.
  defp map_kw_blocks(a_blocks, r_blocks, kinds, fun) do
    [a_blocks, r_blocks]
    |> Enum.zip()
    |> Enum.map(fn {{a_key, a_payload}, {_r_key, r_payload}} ->
      case Map.get(kinds, AST.key_atom(a_key)) do
        :value ->
          {a_key, map_return_tails(a_payload, r_payload, fun)}

        :clauses
        when is_list(a_payload) and is_list(r_payload) and
               length(a_payload) == length(r_payload) ->
          {a_key, map_clauses(a_payload, r_payload, fun)}

        _ ->
          {a_key, a_payload}
      end
    end)
  end

  # Map each `->` clause's body tail (recursing, so a nested control-flow body
  # descends too); a non-`->` element is left untouched. Shared by the def-level
  # `rescue`/`catch`/`else` blocks and every `:clauses` block of a control-flow
  # construct (`case`/`cond`/`receive` `:do`, `with`/`try` clause blocks).
  defp map_clauses(a_clauses, r_clauses, fun) do
    [a_clauses, r_clauses]
    |> Enum.zip()
    |> Enum.map(fn
      {{:->, meta, [pats, a_body]}, {:->, _rmeta, [_rpats, r_body]}} ->
        {:->, meta, [pats, map_return_tails(a_body, r_body, fun)]}

      {a_clause, _r_clause} ->
        a_clause
    end)
  end

  # A keyword-block list: a non-empty list whose every element is a `{key, payload}`
  # pair with an atom key. Fences the generic block walk against a node whose last
  # arg isn't actually a block list (e.g. a hypothetical `try(x)`-style call).
  defp kw_block_list?(blocks) do
    is_list(blocks) and blocks != [] and
      Enum.all?(blocks, fn
        {key, _payload} -> AST.key_atom(key) != nil
        _ -> false
      end)
  end

  # A list of `->` clauses (a `case`/`rescue`/`else`/… clause body list).
  defp clause_list?(list),
    do: is_list(list) and list != [] and Enum.all?(list, &match?({:->, _, _}, &1))

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
