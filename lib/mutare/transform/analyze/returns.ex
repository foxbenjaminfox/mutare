defmodule Mutare.Transform.Analyze.Returns do
  @moduledoc false

  # Return-value mutation: attach return-value candidates to the *leaf return
  # tails* of a `def`/`defp` clause's return-path blocks. A clause returns from its
  # `:do` body tail and each `rescue`/`catch`/`else` clause body tail; and when a
  # tail is itself a `case`/`cond`/`if`/`unless`/`with`/`try`/`receive`, the tail
  # position propagates into each branch body, so every branch's leaf tail is a
  # return path too (`walk_tails/4` + `@return_blocks`). The def-level
  # `rescue`/`catch`/`else` blocks and a `try` *expression*'s clause blocks share
  # one clause walk (`walk_clauses/4`). An **anonymous function** is the same notion
  # one level down: each `fn` clause returns its body's tail when the closure is
  # called, so `annotate_fn_returns/3` runs the very same per-clause leaf-tail walk
  # over a `fn`'s clauses. Split out of `Mutare.Transform.Analyze` — it is a
  # self-contained candidate-builder the main walk calls once per clause
  # (`annotate_returns/3`) or `fn` (`annotate_fn_returns/3`), and it never recurses
  # back into the descent (no `analyze/3`/`offer`/`recurse`), so the dependency is
  # strictly one-way (Analyze → Returns).
  #
  # **Found on the raw tree, delivered by node identity.** The walk reads only the *raw*
  # (pre-analysis) tree: it is the author's code, so it decides where a clause returns
  # from, and each tail's candidate takes its clean `original`/`range` from it. The
  # candidates are then appended to the *analyzed* node carrying the same
  # `Mutare.Transform.Resolve.nid/1`, wherever the analyzer put it (`deliver/2`). The
  # analyzer does move nodes — an `if` whose condition binding is hoisted comes back as
  # `{:__block__, [], hoists ++ [if]}` — so the raw tree's shape is no map of the analyzed
  # one; but it keeps every node's meta, so identity finds each tail. A tail that finds no
  # host raises instead of landing on whatever node occupies its position. See NOTES
  # "Return tails are delivered by node identity".
  #
  # The same leaf-tail descent is also published in **classification** mode
  # (`map_reduce_clause_returns/3` / `map_reduce_fn_returns/3`), for the pre-pass that must see
  # *every* return path of a clause rather than the ones a constant can be attached to
  # (`Mutare.Transform.UnitReturns`, which stamps a unit-returning function's tails so that
  # neither this walk nor the in-place offer touches them — `Meta.unit_tail?/1`). One walker
  # (`walk_tails/4`) threads an accumulator and a `mode` over one tree, so the two notions of
  # "return path" can't drift apart.

  alias Mutare.AST
  alias Mutare.Mutator.Dispatch
  alias Mutare.Transform.{Calls, Candidate, Meta, Resolve}
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

  # The arity at which each `@return_blocks` name really *is* the special form (or `Kernel` macro)
  # it is being read as. At any other arity the same name is an ordinary local or imported
  # function that happens to take a trailing `do:` keyword: `def try(x, opts)` called as
  # `try(1, do: :ok)` is a plain call whose `:ok` is an argument, not a return path. Established
  # empirically — at its own arity the name is unavailable to a local (the compiler rejects
  # `def case(a, b)` and `def if(a, b)`), and at every other arity the local wins. `with` is
  # absent because it is variadic, so it claims every arity.
  @form_arity %{case: 2, cond: 1, if: 2, unless: 2, try: 1, receive: 1}

  # Attach return-value candidates to the *tail expression(s)* of the clause's
  # return-path blocks — the positions a `def`/`defp` clause returns from. This is
  # structural (a tail is a position no node-level mutator can match), so it runs
  # only when some enabled mutator implements `return_replacements/1` (the built-in
  # `Mutare.Mutators.ReturnValue`, or a custom one). The `:do` block
  # returns from its body tail; a `rescue`/`catch`/`else` block returns from
  # *every* clause body's tail (a rescued/caught error or an `else` match is a
  # return path too). `:after` is excluded — `try` discards its value.
  #
  # The tails are found on `raw_kw`, the pre-analysis body keyword, and each candidate is
  # built from its raw tail (so the diff renders the author's tail, un-annotated);
  # `deliver/2` then appends them to the same nodes in `analyzed_kw`, which already carry
  # the operator candidates. `ReturnValue.replacements/1` decides the constant(s) (or that
  # the tail is ineligible).
  def annotate_returns(analyzed_kw, raw_kw, mutators) do
    with_return_mutators(mutators, analyzed_kw, fn return_mutators ->
      {_raw_kw, pending} = walk_body(raw_kw, %{}, tail_collector(return_mutators), :mutate)
      deliver(analyzed_kw, pending)
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
  # clause has, applied per `fn` clause — so the same leaf-tail walk runs over the raw
  # `fn`'s clauses (descending control-flow branches that are themselves in tail
  # position), and a guard (`fn x when … -> body`) stays untouched, riding in the clause's
  # pattern list. Gated on a `return_replacements/_` mutator being enabled, like
  # `annotate_returns/3`.
  #
  # `analyzed` is the whole analyzed `fn` node — its `meta` may already carry the
  # clause-pattern candidates `ClausePatterns.attach_fn_candidates/3` attached — and the
  # candidates found on `raw_node` are delivered into it by identity.
  def annotate_fn_returns(analyzed, {:fn, _meta, raw_clauses}, mutators)
      when is_list(raw_clauses) do
    with_return_mutators(mutators, analyzed, fn return_mutators ->
      {_raw_clauses, pending} =
        walk_clauses(raw_clauses, %{}, tail_collector(return_mutators), :mutate)

      deliver(analyzed, pending)
    end)
  end

  # The `:mutate` leaf function: offer the raw tail to each return mutator and file a
  # `Candidate.Return` per `{spec, replacement}` under the tail's node identity, for
  # `deliver/2`. A tail stamped as a **unit-returning** function's (`Meta.unit_tail?/1`, by
  # `Mutare.Transform.UnitReturns`) is not a value position: no mutator is asked. A tail
  # that would carry candidates but has no identity (a node the resolve pre-pass never
  # stamped) has no host to be delivered to, so it raises as an undelivered tail does.
  defp tail_collector(return_mutators) do
    fn tail, pending ->
      case tail_candidates(tail, return_mutators) do
        [] ->
          {tail, pending}

        candidates ->
          case Resolve.nid(tail) do
            nil -> raise_undelivered!([candidates])
            nid -> {tail, Map.put(pending, nid, candidates)}
          end
      end
    end
  end

  # Every return mutator's replacements for one raw tail, as `Candidate.Return`s ranged on
  # that tail — `[]` for a unit tail, a tail no mutator replaces, or one Sourceror can't
  # range (`Attach.ranged_candidates/2`).
  defp tail_candidates(tail, return_mutators) do
    replacements =
      if Meta.unit_tail?(tail),
        do: [],
        else:
          Enum.flat_map(return_mutators, fn spec ->
            Enum.map(Dispatch.return_replacements(spec, tail), &{spec, &1})
          end)

    case replacements do
      [] ->
        []

      _ ->
        Attach.ranged_candidates(tail, fn range ->
          Enum.map(replacements, fn {spec, replacement} ->
            %Candidate.Return{mutator: spec, original: tail, mutated: replacement, range: range}
          end)
        end)
    end
  end

  # Append each pending tail's candidates to the analyzed node carrying the same identity —
  # *after* any operator candidates already there, so emission builds one selector `case`
  # hosting both an operator swap and the return constant on the same node, ids in
  # attachment order. The analyzer may move a node (the hoisted `if`) but must keep it and
  # its meta, so every pending tail finds its host; a leftover is an analyzer bug, raised
  # rather than attached elsewhere, where it would replace code the author did not write
  # at that return position.
  defp deliver(analyzed, pending) when map_size(pending) == 0, do: analyzed

  defp deliver(analyzed, pending) do
    case Macro.prewalk(analyzed, pending, &deliver_node/2) do
      {delivered, rest} when map_size(rest) == 0 -> delivered
      {_partial, rest} -> raise_undelivered!(Map.values(rest))
    end
  end

  defp deliver_node(node, pending) do
    with nid when nid != nil <- Resolve.nid(node),
         {[_ | _] = candidates, rest} <- Map.pop(pending, nid) do
      {Meta.append_candidates(node, :in_place, candidates), rest}
    else
      _ -> {node, pending}
    end
  end

  @spec raise_undelivered!([[struct()]]) :: no_return()
  defp raise_undelivered!(candidate_lists) do
    tails =
      Enum.map_join(candidate_lists, "; ", fn [%Candidate.Return{} = candidate | _] ->
        "line #{candidate.range.start[:line]}: #{Macro.to_string(candidate.original)}"
      end)

    raise "internal error: return-value candidates found no host node in the analyzed tree " <>
            "(#{tails}). Mutare.Transform.Analyze.Returns delivers them by node identity " <>
            "(meta[:mutare_nid]), so an analyze rewrite may move a return tail but must keep " <>
            "the node and its meta."
  end

  # --- the classification API ---------------------------------------------------

  @doc """
  Map-reduce `fun` over every leaf return tail of a `def`/`defp` clause's body keyword
  (`[do: …, rescue: …, …]`) in **classification** mode — the walk the attach path runs, for a
  pass that must see *every* return path of a clause rather than the ones a return constant can
  be attached to (`Mutare.Transform.UnitReturns`). `fun.(leaf, acc)` returns `{leaf, acc}`; the
  result is `{body_kw, acc}`, with the body's keyword-form clause blocks normalized
  (`Syntax.normalize_clause_blocks/1` — as the analyzer normalizes its own copy).

  Classification is conservative where attachment is permissive, so a caller establishing a
  property of *all* return paths can trust the leaves it is handed:

    * a `try`/`def` with an `else` does not yield its `do` tail at all — the `else` clauses
      *consume* that value and their own tails are what the caller gets;
    * an else-less `with` is delivered **whole** — its first non-matching value is a return path
      with no node of its own (attachment descends only the `do` tail, the one path a constant
      can replace; the implicit one can't be mutated anyway);
    * a construct that is not the form it looks like is delivered whole — a local `try/2` or
      `if/1` (only one arity per name is the real thing), or an `if`/`unless` displaced by
      `import Kernel, except: [if: 2]`: somebody else's function, whose `do:` is an argument;
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
  def map_reduce_clause_returns(body_kw, acc, fun) when is_list(body_kw),
    do: walk_body(body_kw, acc, fun, :classify)

  @doc """
  Map-reduce `fun` over every leaf return tail of an anonymous function's clauses, in
  classification mode (see `map_reduce_clause_returns/3`). Returns `{fn_node, acc}`.
  """
  @spec map_reduce_fn_returns(Macro.t(), acc, (Macro.t(), acc -> {Macro.t(), acc})) ::
          {Macro.t(), acc}
        when acc: term()
  def map_reduce_fn_returns({:fn, meta, clauses}, acc, fun) when is_list(clauses) do
    {clauses, acc} = walk_clauses(clauses, acc, fun, :classify)
    {{:fn, meta, clauses}, acc}
  end

  # --- the leaf-tail walk --------------------------------------------------------

  # A `def`/`defp` body keyword: each block's return path(s), map-reduced, after normalizing the
  # keyword-form clause blocks (idempotent on the attach path, whose body the analyzer already
  # normalized). `def f do … else … end` is an implicit `try`, so its `do` value is *consumed* by
  # the `else` clauses rather than returned — the rule `return_path_kinds/3` applies to the `try`
  # expression.
  defp walk_body(body_kw, acc, fun, mode) do
    blocks = Syntax.normalize_clause_blocks(body_kw)
    consumed_do? = has_else?(blocks)

    Enum.map_reduce(blocks, acc, fn
      {key, payload}, acc ->
        {payload, acc} = walk_body_block(key, payload, consumed_do?, acc, fun, mode)
        {{key, payload}, acc}

      other, acc ->
        {other, acc}
    end)
  end

  # Route one def-level body block to its return path(s): the `:do` body tail, or each
  # `rescue`/`catch`/`else` clause body tail. A `def … rescue/catch/else …` is an implicit
  # `try`, so its clause blocks take the very same `walk_clauses/4` the `try` *expression*
  # uses — one walk, not two. `:after` (and any other key) returns nothing: `try` discards
  # its value. Classification's two conservative departures: it does not yield a `do` an
  # `else` consumes (attachment still descends it — a constant there is a legal swap), and it
  # delivers a clause block that isn't a clean clause list whole (attachment skips it).
  defp walk_body_block(key, payload, consumed_do?, acc, fun, mode) do
    cond do
      Syntax.do_key?(key) ->
        if mode == :classify and consumed_do?,
          do: {payload, acc},
          else: walk_tails(payload, acc, fun, mode)

      Syntax.clause_block_key?(key) and clause_list?(payload) ->
        walk_clauses(payload, acc, fun, mode)

      Syntax.clause_block_key?(key) and mode == :classify ->
        fun.(payload, acc)

      true ->
        {payload, acc}
    end
  end

  # Apply `fun` at every *leaf return tail* of a (possibly control-flow) value. A
  # `case`/`cond`/`if`/`unless`/`with`/`try`/`receive` in tail position propagates the
  # tail position into each of its branch bodies (each is a return path), so `fun` is
  # applied to every branch's leaf tail rather than to the construct as a whole.
  # Everything outside this control-flow *whitelist* (`@return_blocks`) is itself a
  # leaf, so an unknown block macro / call / literal is one tail, and a single-statement
  # `:__block__` (a Sourceror-wrapped literal like `{:__block__, _, [:ok]}`) is
  # intentionally *not* unwrapped (the wrapping block is the node we attach to).
  #
  # Tail position is transitive *and* self-limiting: a multi-statement block only
  # descends its **last** statement, so a `case` that is not itself in tail
  # position (bound to a variable, a non-final statement) is never reached and its
  # branches are correctly not return paths.
  #
  # One tree, two modes: `:mutate` (the attach path — permissive) files candidates by node
  # identity for `deliver/2`; `:classify` adds the conservative fallbacks
  # `map_reduce_clause_returns/3` documents.

  # A statement sequence: the tail is the last statement — recurse into it.
  defp walk_tails({:__block__, meta, stmts}, acc, fun, mode) when length(stmts) >= 2 do
    {init, [last]} = Enum.split(stmts, -1)
    {last, acc} = walk_tails(last, acc, fun, mode)
    {{:__block__, meta, init ++ [last]}, acc}
  end

  # A control-flow construct: route each of its keyword blocks by `@return_blocks`.
  # The block list is always the *last* argument (the `case` scrutinee / `if`
  # condition / `with` qualifiers precede it), so split it off, map it, and rebuild.
  # A construct whose source isn't the form's canonical shape (the last arg isn't a
  # block list, or a `:clauses` block isn't a clause list — see `descendable_blocks?/2`)
  # is a leaf: somebody's macro or function that happens to share the name, returning
  # its own value. So is a construct classification may not descend (`descend?/3`).
  defp walk_tails({form, meta, args} = node, acc, fun, mode)
       when is_map_key(@return_blocks, form) and is_list(args) and args != [] do
    # A skipped construct is an inert leaf (`Mutare.Transform.Analyze`'s dispatcher): nothing
    # inside it is a position, its branch tails included, so the whole node is the tail and the
    # return candidates attach to it — exactly as for a skipped call. Classification agrees: a
    # path it cannot see into is not a literal `:ok`/`nil` tail.
    if Meta.routing(meta) == :skip do
      fun.(node, acc)
    else
      {head, [blocks]} = Enum.split(args, -1)
      # The source may write a clause block in keyword form (`case x, do: (p -> b)`), which
      # wraps the clause list in a `:__block__`; normalize it as the analyzer normalizes its
      # own copy (the clauses inside keep their own meta, so each candidate's
      # `original`/`range` and identity are unaffected).
      blocks = Syntax.normalize_clause_blocks(blocks)
      kinds = return_path_kinds(form, blocks, mode)

      if descendable_blocks?(blocks, kinds) and descend?(node, blocks, mode) do
        {blocks, acc} = walk_kw_blocks(blocks, kinds, acc, fun, mode)
        {{form, meta, head ++ [blocks]}, acc}
      else
        fun.(node, acc)
      end
    end
  end

  # Leaf: any node outside the control-flow whitelist is itself the tail.
  defp walk_tails(node, acc, fun, _mode), do: fun.(node, acc)

  # The construct's return-path blocks, minus any that classification must not claim. A `try`
  # with an `else` **consumes** its `do` value — the `else` clauses match on it and *their* tails
  # are what the caller gets — so the `do` tail is an ordinary value position, not a return path.
  # (Stamping an intermediate `:ok` there would suppress the mutant that flips which `else`
  # clause runs, a real behaviour change under an unchanged return value.) Attachment keeps
  # descending it: a constant there is still a legal swap, which is all that path claims.
  defp return_path_kinds(form, blocks, mode) do
    kinds = Map.fetch!(@return_blocks, form)

    if mode == :classify and form == :try and has_else?(blocks),
      do: Map.delete(kinds, :do),
      else: kinds
  end

  # Whether a construct may be descended at all, rather than delivered whole to the leaf
  # fallback. Only classification declines, and for two reasons:
  #
  #   * an **else-less `with`** returns its first non-matching value as-is — a return path with
  #     no node of its own, so descending as if the `do` tail were the only path would be a
  #     claim about paths this walk cannot see;
  #   * a construct that only *looks* like one — a name at an arity the special form does not
  #     claim (`@form_arity`), or an `if`/`unless` displaced out of `Kernel`
  #     (`foreign_conditional?/1`) — is somebody else's function: its `do:`/`else:` are ordinary
  #     arguments, and it need not return a branch value at all.
  #
  # Attachment descends in both cases: the `do` tail is a position a constant can legally
  # replace, and the `with`'s implicit path can't be mutated anyway.
  defp descend?(_node, _blocks, :mutate), do: true

  defp descend?({form, _meta, args} = node, blocks, :classify),
    do: own_arity?(form, args) and paths_visible?(form, blocks) and not foreign_conditional?(node)

  defp own_arity?(form, args) do
    case Map.fetch(@form_arity, form) do
      {:ok, arity} -> length(args) == arity
      :error -> true
    end
  end

  defp paths_visible?(:with, blocks), do: has_else?(blocks)
  defp paths_visible?(_form, _blocks), do: true

  # Whether an `if`/`unless` at its *own* arity is nonetheless not `Kernel`'s. These two alone
  # are askable: they are `Kernel` macros, which `import Kernel, except: [if: 2]` can displace,
  # whereas nothing can displace a special form at the arity it claims. Read the way every
  # bare-`Kernel` family reads one — an unresolved bare call is `Kernel`'s unless the resolver
  # stamped it displaced (the replacement out of reach); a resolved one names its module.
  defp foreign_conditional?({form, _meta, _args} = node) when form in [:if, :unless],
    do: not Calls.kernel_call?(node)

  defp foreign_conditional?(_node), do: false

  # Whether a keyword-block list carries an `else` block. Total: it runs before
  # `descendable_blocks?/2` has vouched for the list's shape.
  defp has_else?(blocks) when is_list(blocks) do
    Enum.any?(blocks, fn
      {key, _payload} -> AST.key_atom(key) == :else
      _other -> false
    end)
  end

  defp has_else?(_blocks), do: false

  # Whether a construct's (normalized) block list is the form's canonical shape: a
  # keyword-block list whose every `:clauses` block carries a clean `->` clause list.
  # (`:value` blocks are always fine; an `if x, do: a, else: b` keyword form has no
  # clauses.)
  defp descendable_blocks?(blocks, kinds) do
    kw_block_list?(blocks) and
      Enum.all?(blocks, fn {key, payload} ->
        case Map.get(kinds, AST.key_atom(key)) do
          :clauses -> clause_list?(payload)
          _ -> true
        end
      end)
  end

  # Map a keyword-block list `[{key, payload}]` by a `%{key => :value | :clauses}`
  # spec: a `:value` payload is recursed as a single tail; a `:clauses` payload has
  # each `->` clause body recursed; a key absent from the spec (a discarded `try`
  # `:after`) passes through untouched.
  defp walk_kw_blocks(blocks, kinds, acc, fun, mode) do
    Enum.map_reduce(blocks, acc, fn {key, payload}, acc ->
      case Map.get(kinds, AST.key_atom(key)) do
        :value ->
          {payload, acc} = walk_tails(payload, acc, fun, mode)
          {{key, payload}, acc}

        :clauses ->
          {payload, acc} = walk_clauses(payload, acc, fun, mode)
          {{key, payload}, acc}

        nil ->
          {{key, payload}, acc}
      end
    end)
  end

  # Map each `->` clause's body tail (recursing, so a nested control-flow body
  # descends too); a non-`->` element is left untouched. Shared by the def-level
  # `rescue`/`catch`/`else` blocks, every `:clauses` block of a control-flow
  # construct (`case`/`cond`/`receive` `:do`, `with`/`try` clause blocks), and a `fn`'s
  # clauses.
  defp walk_clauses(clauses, acc, fun, mode) do
    Enum.map_reduce(clauses, acc, fn
      {:->, meta, [pats, body]}, acc ->
        {body, acc} = walk_tails(body, acc, fun, mode)
        {{:->, meta, [pats, body]}, acc}

      clause, acc ->
        {clause, acc}
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
end
