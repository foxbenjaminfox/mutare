defmodule Mutare.Transform.Analyze.Returns do
  @moduledoc false

  # Return-value mutation: attach return-value candidates to the *leaf return
  # tails* of a `def`/`defp` clause's return-path blocks. A clause returns from its
  # `:do` body tail and each `rescue`/`catch`/`else` clause body tail; and when a
  # tail is itself a `case`/`cond`/`if`/`unless`/`with`/`try`/`receive`, the tail
  # position propagates into each branch body, so every branch's leaf tail is a
  # return path too (`map_return_tails/3` + `@return_blocks`). The def-level
  # `rescue`/`catch`/`else` blocks and a `try` *expression*'s clause blocks share
  # one clause walk (`map_clauses/3`). An **anonymous function** is the same notion
  # one level down: each `fn` clause returns its body's tail when the closure is
  # called, so `annotate_fn_returns/3` runs the very same per-clause leaf-tail walk
  # over a `fn`'s clauses. Split out of `Mutare.Transform.Analyze` — it is a
  # self-contained candidate-builder the main walk calls once per clause
  # (`annotate_returns/3`) or `fn` (`annotate_fn_returns/3`), and it never recurses
  # back into the descent (no `analyze/3`/`offer`/`recurse`), so the dependency is
  # strictly one-way (Analyze → Returns).
  #
  # The same leaf-tail descent is also published single-tree, in **classification** mode
  # (`map_reduce_clause_returns/3` / `map_reduce_fn_returns/3`), for the pre-pass that must see
  # *every* return path of a clause rather than the ones a constant can be attached to
  # (`Mutare.Transform.UnitReturns`, which stamps a unit-returning function's tails so that
  # neither this walk nor the in-place offer touches them — `Meta.unit_tail?/1`). One walker
  # (`walk_tails/5`) threads an accumulator and a `mode`, so the two notions of "return path"
  # can't drift apart.

  alias Mutare.AST
  alias Mutare.Mutator.Dispatch
  alias Mutare.Transform.{Candidate, Meta}
  alias Mutare.Transform.Analyze.{Attach, Syntax}

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
    with_return_mutators(mutators, analyzed_kw, fn return_mutators ->
      Enum.zip_with(analyzed_kw, raw_kw, fn {key, analyzed_value}, {_key, raw_value} ->
        {key, annotate_block_returns(key, analyzed_value, raw_value, return_mutators)}
      end)
    end)
  end

  # The shared enablement gate for the `:return_replacements/{1,2}` hook, used by both return-tail
  # paths (`def`/`defp` blocks and `fn` clauses): run `fun` with the enabled return mutators, or
  # return `default` unchanged when none is enabled — so the `[1, 2]` arity pair (the base +
  # context-aware forms) lives in one place.
  defp with_return_mutators(mutators, default, fun) do
    case Dispatch.implementing_any(mutators, :return_replacements, [1, 2]) do
      [] -> default
      return_mutators -> fun.(return_mutators)
    end
  end

  # Attach return-value candidates to each clause body's *leaf return tail(s)* of an
  # anonymous function. A `fn`'s every clause returns the value of its body's tail
  # expression when the closure is called — the same return notion a `def`/`defp`
  # clause has, applied per `fn` clause — so the same leaf-tail walk runs:
  # `map_clauses/3` recurses each clause body via `map_return_tails/3` (descending
  # control-flow branches that are themselves in tail position), and the
  # `build_leaf_attacher` closure offers each leaf to every return mutator. Gated on a
  # `return_replacements/_` mutator being enabled, like `annotate_returns/3`.
  #
  # The whole `fn` node is taken (its `meta` may already carry the clause-pattern
  # candidates `ClausePatterns.attach_clause_pattern_candidates/5` attached) and
  # rebuilt with the annotated clauses; `raw_node` is the pre-analysis copy supplying
  # each candidate's clean `original`/`range`, navigated in lockstep with `analyzed`
  # (analysis only adds metadata). A structural surprise (mismatched shape/length —
  # shouldn't happen) passes the analyzed node through untouched.
  def annotate_fn_returns(
        {:fn, meta, analyzed_clauses} = analyzed,
        {:fn, _rmeta, raw_clauses},
        mutators
      )
      when is_list(analyzed_clauses) and is_list(raw_clauses) and
             length(analyzed_clauses) == length(raw_clauses) do
    with_return_mutators(mutators, analyzed, fn return_mutators ->
      {:fn, meta,
       map_clauses(analyzed_clauses, raw_clauses, build_leaf_attacher(return_mutators))}
    end)
  end

  def annotate_fn_returns(analyzed, _raw_node, _mutators), do: analyzed

  # Route one `def`/`defp` body block to its return path(s): the `:do` body tail,
  # or each `rescue`/`catch`/`else` clause body tail. A `def … rescue/catch/else …`
  # is an implicit `try`, so its clause blocks are mapped by the very same
  # `map_clauses/3` the `try` *expression* uses (`map_return_tails/3` below) — one
  # walk, not two. `:after` (and any other key) returns nothing: `try` discards its
  # value, and its expression payload isn't a clause list so it falls through here.
  defp annotate_block_returns(key, analyzed, raw, return_mutators) do
    cond do
      Syntax.do_key?(key) ->
        attach_return(analyzed, raw, return_mutators)

      Syntax.clause_block_key?(key) and clause_list?(analyzed) and clause_list?(raw) and
          length(analyzed) == length(raw) ->
        map_clauses(analyzed, raw, build_leaf_attacher(return_mutators))

      true ->
        analyzed
    end
  end

  # Build the leaf-attaching closure (`fn analyzed_tail, raw_tail -> … end`) shared by every
  # path: offer the tail to each return mutator and
  # append a `Candidate.Return` per `{spec, replacement}` (the mutator's
  # `return_replacements/1` output, tagged with its spec). The candidates ride in
  # the tail node's own `meta[:mutare]` — *after* any operator candidates already
  # there — so emission builds one selector `case` hosting both an operator swap
  # and the return constant on the same node, ids in attachment order. A tail
  # stamped as a **unit-returning** function's (`Meta.unit_tail?/1`, by
  # `Mutare.Transform.UnitReturns`) is not a value position: no mutator is asked.
  defp build_leaf_attacher(return_mutators) do
    fn analyzed_tail, raw_tail ->
      if Meta.unit_tail?(raw_tail) do
        analyzed_tail
      else
        replacements =
          Enum.flat_map(return_mutators, fn spec ->
            Enum.map(Dispatch.return_replacements(spec, raw_tail), &{spec, &1})
          end)

        case replacements do
          [] -> analyzed_tail
          _ -> append_return_candidates(analyzed_tail, raw_tail, replacements)
        end
      end
    end
  end

  # Find every *leaf return tail* reachable from a `:do` block — the last statement
  # of a multi-statement block, and (transitively) each branch body of a
  # `case`/`cond`/`if`/`unless`/`with`/`try`/`receive` in tail position — and attach
  # the return candidates there.
  defp attach_return(analyzed_value, raw_value, return_mutators) do
    map_return_tails(analyzed_value, raw_value, build_leaf_attacher(return_mutators))
  end

  # --- the single-tree classification walk --------------------------------------

  @doc """
  Map-reduce `fun` over every leaf return tail of a `def`/`defp` clause's body keyword
  (`[do: …, rescue: …, …]`) in **classification** mode — the single-tree twin of the lockstep
  attach walk, for a pass that must see *every* return path of a clause rather than the ones a
  return constant can be attached to (`Mutare.Transform.UnitReturns`). `fun.(leaf, acc)` returns
  `{leaf, acc}`; the result is `{body_kw, acc}`, with the body's keyword-form clause blocks
  normalized (`Syntax.normalize_clause_blocks/1` — as the analyzer normalizes its own copy).

  Classification is conservative where attachment is permissive, so a caller establishing a
  property of *all* return paths can trust the leaves it is handed:

    * an else-less `with` is delivered **whole** — its first non-matching value is a return path
      with no node of its own (attachment descends only the `do` tail, the one path a constant
      can replace; the implicit one can't be mutated anyway);
    * a `rescue`/`catch`/`else` block that isn't a clean clause list is delivered whole, not
      skipped.

  A `try`'s `after` is not a return path in either mode (`try` discards its value).
  """
  @spec map_reduce_clause_returns(
          [{Macro.t(), Macro.t()}],
          acc,
          (Macro.t(), acc -> {Macro.t(), acc})
        ) :: {[{Macro.t(), Macro.t()}], acc}
        when acc: term()
  def map_reduce_clause_returns(body_kw, acc, fun) when is_list(body_kw) do
    body_kw
    |> Syntax.normalize_clause_blocks()
    |> Enum.map_reduce(acc, fn
      {key, payload}, acc ->
        {payload, acc} = classify_block(key, payload, acc, fun)
        {{key, payload}, acc}

      other, acc ->
        {other, acc}
    end)
  end

  # Route one def-level body block to its return path(s) for classification — the twin of
  # `annotate_block_returns/4`, with the conservative fallbacks the docs above promise.
  defp classify_block(key, payload, acc, fun) do
    cond do
      Syntax.do_key?(key) ->
        walk_tails(payload, payload, acc, single(fun), :classify)

      Syntax.clause_block_key?(key) and clause_list?(payload) ->
        walk_clauses(payload, payload, acc, single(fun), :classify)

      Syntax.clause_block_key?(key) ->
        fun.(payload, acc)

      true ->
        {payload, acc}
    end
  end

  @doc """
  Map-reduce `fun` over every leaf return tail of an anonymous function's clauses, in
  classification mode (see `map_reduce_clause_returns/3`). Returns `{fn_node, acc}`.
  """
  @spec map_reduce_fn_returns(Macro.t(), acc, (Macro.t(), acc -> {Macro.t(), acc})) ::
          {Macro.t(), acc}
        when acc: term()
  def map_reduce_fn_returns({:fn, meta, clauses}, acc, fun) when is_list(clauses) do
    {clauses, acc} = walk_clauses(clauses, clauses, acc, single(fun), :classify)
    {{:fn, meta, clauses}, acc}
  end

  # Lift a single-tree leaf function to the walker's `(analyzed, raw, acc)` shape — the two
  # trees are one, so the raw side is dropped.
  defp single(fun), do: fn leaf, _raw, acc -> fun.(leaf, acc) end

  # --- the leaf-tail walk --------------------------------------------------------

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
  #
  # The walker proper (`walk_tails/5`) threads an accumulator and a `mode`, so one
  # descent serves both this lockstep *map* and the single-tree *map-reduce* of the
  # classification API above: `:mutate` is the attach path (permissive — the prior
  # behaviour, bit for bit); `:classify` adds the conservative fallbacks
  # `map_reduce_clause_returns/3` documents.
  defp map_return_tails(analyzed, raw, fun) do
    {mapped, nil} = walk_tails(analyzed, raw, nil, fn a, r, nil -> {fun.(a, r), nil} end, :mutate)
    mapped
  end

  # A statement sequence: the tail is the last statement — recurse into it.
  # NOTE (equivalent survivor, deliberately not `# mutare:ignore`d so the killed
  # `-> false` sibling stays counted): `length(a_stmts) == length(r_stmts)` is a defensive
  # assertion that always holds (analyzed and raw are the same block with only metadata
  # added), so forcing it `true` is equivalent; forcing it `false` is killed.
  defp walk_tails({:__block__, meta, a_stmts}, {:__block__, _rmeta, r_stmts}, acc, fun, mode)
       when length(a_stmts) >= 2 and length(a_stmts) == length(r_stmts) do
    {a_init, [a_last]} = Enum.split(a_stmts, -1)
    {_r_init, [r_last]} = Enum.split(r_stmts, -1)
    {a_last, acc} = walk_tails(a_last, r_last, acc, fun, mode)
    {{:__block__, meta, a_init ++ [a_last]}, acc}
  end

  # A control-flow construct: route each of its keyword blocks by `@return_blocks`.
  # The block list is always the *last* argument (the `case` scrutinee / `if`
  # condition / `with` qualifiers precede it), so split it off, map it, and rebuild.
  # A non-descendable shape (the last arg isn't a block list, or a `:clauses` block
  # isn't in canonical block form — see `descendable_blocks?/3`) falls through to
  # the leaf clause: the whole construct is then the tail, as before this descent.
  # So does a construct with a return path no block shows (`complete?/3`).
  defp walk_tails({form, meta, a_args} = analyzed, {form, _rmeta, r_args} = raw, acc, fun, mode)
       when is_map_key(@return_blocks, form) and is_list(a_args) and is_list(r_args) and
              a_args != [] and length(a_args) == length(r_args) do
    # A skipped construct is an inert leaf (`Mutare.Transform.Analyze`'s dispatcher): nothing
    # inside it is a position, its branch tails included, so the whole node is the tail and the
    # return candidates attach to it — exactly as for a skipped call. Classification agrees: a
    # path it cannot see into is not a literal `:ok`/`nil` tail.
    if Meta.routing(meta) == :skip do
      fun.(analyzed, raw, acc)
    else
      {a_head, [a_blocks]} = Enum.split(a_args, -1)
      {_r_head, [r_blocks]} = Enum.split(r_args, -1)
      # The analyzed copy's keyword-form clause tails were normalized at the construct's
      # analyze clause; the raw copy still carries the source's `:__block__` wrapper.
      # Normalize it too so the lockstep walk stays aligned (the clauses inside keep
      # their own meta, so each candidate's `original`/`range` is unaffected). In
      # classification mode the one tree *is* the un-analyzed source, so it gets the
      # same normalization; the attach path's analyzed side is left exactly as it came.
      r_blocks = Syntax.normalize_clause_blocks(r_blocks)
      a_blocks = if mode == :classify, do: r_blocks, else: a_blocks
      kinds = Map.fetch!(@return_blocks, form)

      if descendable_blocks?(a_blocks, r_blocks, kinds) and complete?(form, a_blocks, mode) do
        {blocks, acc} = walk_kw_blocks(a_blocks, r_blocks, kinds, acc, fun, mode)
        {{form, meta, a_head ++ [blocks]}, acc}
      else
        fun.(analyzed, raw, acc)
      end
    end
  end

  # Leaf: any node outside the control-flow whitelist is itself the tail.
  defp walk_tails(analyzed, raw, acc, fun, _mode), do: fun.(analyzed, raw, acc)

  # Whether every return path of a construct is *visible* as a block tail. Only classification
  # asks: an else-less `with` returns its first non-matching value as-is — a return path with no
  # node — so in `:classify` mode the construct is delivered whole (the leaf fallback) rather
  # than descended as if its `do` tail were the only path. Attachment keeps descending: the `do`
  # tail is the one path a constant can replace, and the implicit one can't be mutated anyway.
  defp complete?(:with, blocks, :classify),
    do: Enum.any?(blocks, fn {key, _payload} -> AST.key_atom(key) == :else end)

  defp complete?(_form, _blocks, _mode), do: true

  # Whether a construct's block list is safe to descend. It must be a keyword-block
  # list (both copies, equal length) whose every `:clauses` block carries a clean
  # `->` clause list. The **keyword form** (`with …, else: (c -> …)`, `case x, do:
  # (… -> …)`) wraps that clause list in an extra `:__block__` — but both copies
  # arrive here `Syntax.normalize_clause_blocks/1`-ed (the analyzed copy at the
  # construct's analyze clause, the raw copy just above), so the keyword form
  # descends exactly like its block-form twin. A construct that is *still*
  # non-canonical (a malformed shape) is left a leaf (mutated whole — which renders
  # fine). (`:value` blocks are always fine; an `if x, do: a, else: b` keyword form
  # has no clauses.)
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
  defp walk_kw_blocks(a_blocks, r_blocks, kinds, acc, fun, mode) do
    a_blocks
    |> Enum.zip(r_blocks)
    |> Enum.map_reduce(acc, fn {{a_key, a_payload}, {_r_key, r_payload}}, acc ->
      case Map.get(kinds, AST.key_atom(a_key)) do
        :value ->
          {payload, acc} = walk_tails(a_payload, r_payload, acc, fun, mode)
          {{a_key, payload}, acc}

        :clauses
        when is_list(a_payload) and is_list(r_payload) and
               length(a_payload) == length(r_payload) ->
          {payload, acc} = walk_clauses(a_payload, r_payload, acc, fun, mode)
          {{a_key, payload}, acc}

        _ ->
          {{a_key, a_payload}, acc}
      end
    end)
  end

  # Map each `->` clause's body tail (recursing, so a nested control-flow body
  # descends too); a non-`->` element is left untouched. Shared by the def-level
  # `rescue`/`catch`/`else` blocks and every `:clauses` block of a control-flow
  # construct (`case`/`cond`/`receive` `:do`, `with`/`try` clause blocks).
  defp map_clauses(a_clauses, r_clauses, fun) do
    {mapped, nil} =
      walk_clauses(a_clauses, r_clauses, nil, fn a, r, nil -> {fun.(a, r), nil} end, :mutate)

    mapped
  end

  defp walk_clauses(a_clauses, r_clauses, acc, fun, mode) do
    a_clauses
    |> Enum.zip(r_clauses)
    |> Enum.map_reduce(acc, fn
      {{:->, meta, [pats, a_body]}, {:->, _rmeta, [_rpats, r_body]}}, acc ->
        {body, acc} = walk_tails(a_body, r_body, acc, fun, mode)
        {{:->, meta, [pats, body]}, acc}

      {a_clause, _r_clause}, acc ->
        {a_clause, acc}
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
  # node, or one Sourceror can't range) gets no return mutant — handled by the shared
  # `Attach.append_candidates/3`.
  defp append_return_candidates(node, raw_tail, replacements) do
    Attach.append_candidates(node, raw_tail, fn range ->
      Enum.map(replacements, fn {spec, replacement} ->
        %Candidate.Return{
          mutator: spec,
          original: raw_tail,
          mutated: replacement,
          range: range
        }
      end)
    end)
  end
end
