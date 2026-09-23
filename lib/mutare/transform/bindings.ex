defmodule Mutare.Transform.Bindings do
  @moduledoc false

  # The **scope** pre-pass: what a selector's export needs to know about the names around it.
  #
  # An in-place selector is a `case`, and a `case` branch traps what it binds; so a mutated
  # expression's bindings are re-exported through a tuple and rebound outside
  # (`Mutare.Transform.PipeEmit`). Which names a branch *can* export depends on the scope the
  # expression stands in, and no reading of the expression alone can say:
  #
  #   * a name **bound on entry** can be exported by every branch, whether it rebinds the name
  #     or not — a branch that does not names the incoming value, which is what the source
  #     leaves after a rebinding a mutant removed (`p = :before; count(xs, p = f)` → `count(xs)`
  #     leaves `p == :before`) — **unless an earlier sibling of the same expression writes it**.
  #     Elixir resets reads between the siblings of a call, a tuple, a list, an operator or a
  #     map (`foo(x = 1, x)` does not compile) and lets their writes out only after the whole
  #     expression, the last one winning; so the "incoming" value read at the second sibling
  #     is the one from before the expression, and exporting it would override the first
  #     sibling's write. Such a name is a **conflict**: bound, but not exportable as incoming.
  #   * a name the expression binds **fresh** can be exported only by the branches that bind
  #     it, and a conflict only by the branches that write it. A mutant that drops such a
  #     binding is source-valid only where nothing **reads the name after** it: the binding
  #     then goes unexported, and the catch-all's copy stays trapped, unread. Where something
  #     does read it, the mutant's own source patch would not compile (fresh) or its delivery
  #     would override the sibling's write (conflict), so the mutant is withheld
  #     (`Mutare.Transform.Candidate.Delivery.gate/2`).
  #
  # So this pass stamps every binding-bearing node with `{bound, conflicts, later}`: the names
  # bound on entry, those of them an earlier sibling writes, and the names referenced after
  # the node. Each errs to one side only. `bound` may miss a bound name (the node then takes
  # the fresh rule, which is what every node took before this pass), never claim an unbound
  # one (an export naming it would not compile). `conflicts` may over-count (an export
  # withheld for nothing), never miss. `later` may name a read that never happens (a mutant
  # withheld for nothing), never miss one. The default `Meta.bindings/1` answers for an
  # unstamped node — a host's island, whose enclosing scope core never sees — errs the same
  # way: nothing bound, everything read.
  #
  # `bound` follows Elixir's scoping where it is plain and stays silent where it is not: a
  # definition's head patterns; a block's statements in order, each adding what
  # `Mutare.Transform.BindingEscapeEmit.expression_bindings/1` says escapes it, so an unrouted
  # call is a function here too — a parenthesized block anywhere is the same sequence; the
  # clauses of `case`/`cond`/`fn`/`receive`/`try`/`with`/`for`, each seeing its own patterns;
  # and a `Kernel` `if`/`unless` condition. A statement's write clears a conflict on the name.
  # The siblings of an expression — a call's callee and arguments, a tuple's or list's
  # elements, an operator's operands, a keyword pair's key and value — each get the entry set
  # with what the siblings before them **may** write added to `conflicts`: a match anywhere
  # in the sibling, whether or not its execution or escape is certain (a `:lazy_expression`
  # position's `p = 8` is not a guaranteed binding, but it is a possible write, and the
  # sibling after it may not export the stale `p`). A routed macro's positions take every
  # other position's possible writes as conflicts, their order being the macro's, and see
  # every other position's references as `later` for the same reason.
  # A module body binds nothing for the definitions inside it. Nothing under a `quote`, a
  # routed foreign region, or a skipped call is stamped: nothing there is offered.
  #
  # `later` is every variable-shaped name in what follows the node in evaluation order — the
  # later siblings, then the enclosing node's, out to the body the node is in — with the match
  # forms (`=`, `<-`) read value first, since a pin in their pattern reads after the value. It
  # stops at the body of a definition, a `fn` or a structural form's clause, whose bindings
  # Elixir never lets out; inside one it applies no scoping, since a fresh name read outside
  # the scope that binds it is a source error, and counting it costs nothing.
  #
  # Runs after `Mutare.Transform.UnitReturns` (meta-only, so every earlier stamp survives) and
  # on a host's island as it is resolved (`Mutare.Transform.Analyze.Collect`), from a scope
  # that binds nothing and has everything after it.

  alias Mutare.AST
  alias Mutare.Transform.{BindingEscapeEmit, Calls, KeywordRouting, Meta, PatternStructure}
  alias Mutare.Transform.Resolve

  @typedoc "Names bound on entry, those an earlier sibling writes, and names referenced after (`:all` when unknown)."
  @type stamp :: {MapSet.t(atom()), MapSet.t(atom()), MapSet.t(atom()) | :all}

  # The entry scope threaded down the walk: `{bound, conflicts}`.
  @typep scope :: {MapSet.t(atom()), MapSet.t(atom())}

  @definitions [:def, :defp, :defmacro, :defmacrop]
  @modules [:defmodule, :defimpl, :defprotocol]
  @structural [:case, :cond, :if, :unless, :with, :for, :try, :receive]
  @values [:expression, :interior, :lazy_expression]

  @doc """
  Stamp every binding-bearing node of `tree` with its `t:stamp/0` (`Meta.bindings/1`).

  `island?: true` walks a fragment whose surroundings are unknown: nothing bound on entry,
  everything read after.
  """
  @spec annotate(Macro.t(), keyword()) :: Macro.t()
  def annotate(tree, opts \\ []) do
    later = if Keyword.get(opts, :island?, false), do: :all, else: MapSet.new()
    {tree, _referenced, _binds?} = walk(tree, scope_new(), later)
    tree
  end

  @doc """
  Every name a match anywhere inside `node` may bind — `=` and `<-` patterns, and the
  positions a route declares binding (`destructure/2`'s `:binding_pattern`, keyed refinements
  included) — at any depth, whatever scope or treatment encloses them. A superset of what is
  guaranteed to escape: a name here that is already bound on entry may be rebound by the
  node, and an export naming it costs at worst an identity; and it is what a sibling *may*
  write, which a conflict must count even where the write's execution is not certain.

  Inside a skipped call's arguments, which Resolve did not walk, a call's route is read
  through the environment the skipped call retains (`Resolve.preserved_routing/2`), as
  `BindingEscapeEmit.expression_bindings/1` reads it: skip withholds mutation, not evaluation.
  A route there that is a classifier cannot be read, and the names it declares are missing
  from this list; `unknown_routing?/1` says so.
  """
  @spec matched_names(Macro.t()) :: [atom()]
  def matched_names(node) do
    for {:bound, name} <- matched(node, %{}), uniq: true, do: name
  end

  @doc """
  Whether `node` contains a call whose binding effect cannot be read: one inside a skipped
  call's argument whose route is a `:routing` classifier, which is never invoked in a region
  it was withheld from (`Resolve.preserved_routing/2`). Such a call may bind names neither
  reader reports, so a delivery that must export what `node` binds withholds instead
  (`Candidate.Delivery.gate/2`); a call is read as ordinary only where no route is declared.
  """
  @spec unknown_routing?(Macro.t()) :: boolean()
  def unknown_routing?(node), do: :unknown in matched(node, %{})

  # The walk collects binding facts: `{:bound, name}` for a possible write, `:unknown` for a
  # call whose declared positions could not be obtained.
  defp matched({:__block__, _meta, statements}, context) when is_list(statements) do
    {names, _context} =
      Enum.map_reduce(statements, context, fn statement, context ->
        {matched(statement, context), Resolve.advance_context(statement, context)}
      end)

    List.flatten(names)
  end

  defp matched({match, _meta, [pattern, value]}, context) when match in [:=, :<-] do
    bound(PatternStructure.bound_var_names(pattern)) ++
      matched(pattern, context) ++ matched(value, context)
  end

  # A surviving pipe is a withheld Kernel stage, read as the call it denotes, or an operator.
  defp matched({:|>, _meta, _args} = pipe, context) do
    context = Resolve.context(pipe, context)

    case Resolve.preserved_pipe_call(pipe, context) do
      nil -> matched_call(pipe, context)
      call -> matched(call, context)
    end
  end

  defp matched({_form, meta, args} = node, context) when is_list(meta) and is_list(args),
    do: matched_call(node, Resolve.context(node, context))

  defp matched({form, meta, _context}, context) when is_list(meta), do: matched(form, context)

  defp matched({left, right}, context), do: matched(left, context) ++ matched(right, context)

  defp matched(list, context) when is_list(list), do: Enum.flat_map(list, &matched(&1, context))

  defp matched(_leaf, _context), do: []

  defp matched_call({form, _meta, args} = node, context) do
    declared_names(args, routing(node, context)) ++
      matched(form, context) ++ matched(args, context)
  end

  # A stamped call's route, or the static route a call inside a skipped argument resolves to
  # (`:unknown` where that route is a classifier this reader cannot invoke).
  defp routing({_form, meta, _args} = node, context),
    do: Meta.routing(meta) || Resolve.preserved_routing(node, context)

  # The names a call's route declares its positions bind.
  defp declared_names(args, routes) when is_list(routes) do
    args
    |> Enum.zip(routes)
    |> Enum.flat_map(fn {arg, treatment} -> declared_position_names(arg, treatment) end)
  end

  defp declared_names(_args, :unknown), do: [:unknown]
  defp declared_names(_args, _routing), do: []

  defp bound(names), do: Enum.map(names, &{:bound, &1})

  defp declared_position_names(arg, :binding_pattern),
    do: bound(PatternStructure.bound_var_names(arg))

  defp declared_position_names(arg, {:keyword, _} = treatment),
    do: declared_keyword_names(arg, treatment)

  defp declared_position_names(arg, {:keyed, _, _} = treatment),
    do: declared_keyword_names(arg, treatment)

  defp declared_position_names(_arg, _treatment), do: []

  defp declared_keyword_names(arg, treatment) do
    case KeywordRouting.decode(arg, treatment) do
      {:pairs, pairs, _rewrap} ->
        Enum.flat_map(pairs, fn {{key, key_treatment}, {value, value_treatment}} ->
          declared_position_names(key, key_treatment) ++
            declared_position_names(value, value_treatment)
        end)

      {:whole, fallback} ->
        declared_position_names(arg, fallback)
    end
  end

  @doc "Every variable-shaped name anywhere inside `node` — a read, a binding, or a pattern."
  @spec referenced_names(Macro.t()) :: MapSet.t(atom())
  def referenced_names(node) do
    node
    |> Macro.prewalk(MapSet.new(), fn
      {name, _meta, context} = node, acc when is_atom(name) and is_atom(context) ->
        {node, MapSet.put(acc, name)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # --- the scope ----------------------------------------------------------------------------

  @spec scope_new() :: scope()
  defp scope_new, do: {MapSet.new(), MapSet.new()}

  # A statement, pattern or head binds `names`: readable from here on, and no longer in
  # conflict with anything written before.
  defp bind({bound, conflicts}, names) do
    names = MapSet.new(names)
    {MapSet.union(bound, names), MapSet.difference(conflicts, names)}
  end

  # An earlier sibling writes `names`: still bound (if they were), not exportable as incoming.
  defp conflict({bound, conflicts}, names),
    do: {bound, MapSet.union(conflicts, MapSet.new(names))}

  # --- the walk: `{node, names referenced inside, whether anything inside binds}` ------------

  defp walk({:quote, _meta, _args} = node, _scope, _later), do: opaque(node)

  defp walk({match, meta, [pattern, value]}, scope, later) when match in [:=, :<-] do
    pattern_names = referenced_names(pattern)
    {value, referenced, _binds?} = walk(value, scope, union(later, pattern_names))
    {{match, stamp(meta, scope, later), [pattern, value]}, union(referenced, pattern_names), true}
  end

  defp walk({:->, _meta, _args} = node, scope, later), do: clause(node, :bare, scope, later)

  # A parenthesized block is a statement sequence wherever it stands.
  defp walk({:__block__, meta, statements}, scope, later) when is_list(statements) do
    {statements, referenced, binds?} = sequence(statements, scope, later, :statements)
    {{:__block__, stamp_if(meta, binds?, scope, later), statements}, referenced, binds?}
  end

  defp walk({form, meta, args} = node, scope, later) when is_list(meta) and is_list(args) do
    cond do
      Meta.routing(meta) == :skip ->
        opaque(node)

      form in @modules and Calls.kernel_call?(node) ->
        module(node, later)

      form in @definitions and Calls.kernel_call?(node) ->
        definition(node, later)

      form == :fn or (form in @structural and Calls.kernel_call?(node)) ->
        structural(node, scope, later)

      true ->
        call(node, scope, later)
    end
  end

  # A variable, or a node whose head is one.
  defp walk({form, meta, context} = node, scope, later) when is_list(meta) do
    {form, referenced, binds?} = walk(form, scope, later)
    {{form, meta, context}, put_name(referenced, node), binds?}
  end

  defp walk({left, right}, scope, later) do
    {[left, right], referenced, binds?} = sequence([left, right], scope, later, :siblings)
    {{left, right}, referenced, binds?}
  end

  defp walk(list, scope, later) when is_list(list), do: sequence(list, scope, later, :siblings)

  defp walk(leaf, _scope, _later), do: {leaf, MapSet.new(), false}

  defp put_name(referenced, {name, _meta, context}) when is_atom(name) and is_atom(context),
    do: MapSet.put(referenced, name)

  defp put_name(referenced, _node), do: referenced

  # Not walked; still read for what it references and whether it binds.
  defp opaque(node), do: {node, referenced_names(node), matched_names(node) != []}

  # --- modules and definitions --------------------------------------------------------------

  # A module body binds nothing for what is defined inside it: its statements are walked from
  # an empty scope, and a module-level match adds nothing for the statements after it.
  defp module({form, meta, args}, later) do
    {lead, [last]} = Enum.split(args, -1)
    {last, referenced, binds?} = module_body(last, later)
    {{form, meta, lead ++ [last]}, referenced, binds?}
  end

  defp module_body([{key, {:__block__, meta, statements}} | rest], later)
       when is_list(statements) do
    {statements, referenced, binds?} = sequence(statements, scope_new(), later, :unsequenced)
    {rest, rest_referenced, rest_binds?} = walk(rest, scope_new(), later)

    {[{key, {:__block__, meta, statements}} | rest], union(referenced, rest_referenced),
     binds? or rest_binds?}
  end

  defp module_body(body, later), do: walk(body, scope_new(), later)

  # The head's patterns are bound throughout the body, whose `do`/`rescue`/`catch`/`else`/
  # `after` blocks scope as a `try`'s do. A default is evaluated in a generated clause.
  defp definition({form, meta, [head]}, _later) do
    {head, referenced, binds?} = head(head)
    {{form, meta, [head]}, referenced, binds?}
  end

  defp definition({form, meta, [head, body]}, _later) when is_list(body) do
    {head, head_referenced, head_binds?} = head(head)
    scope = bind(scope_new(), head_names(head))
    {body, referenced, binds?} = blocks(:try, body, scope)
    {{form, meta, [head, body]}, union(head_referenced, referenced), head_binds? or binds?}
  end

  defp definition(node, later), do: call(node, scope_new(), later)

  defp head({:when, meta, [call | guards]}) do
    {call, referenced, binds?} = head(call)
    {{:when, meta, [call | guards]}, union(referenced, referenced_names(guards)), binds?}
  end

  defp head({name, meta, params}) when is_list(params) do
    {params, referenced, binds?} =
      Enum.reduce(Enum.reverse(params), {[], MapSet.new(), false}, fn param,
                                                                      {acc, referenced, binds?} ->
        {param, param_referenced, param_binds?} = param(param)
        {[param | acc], union(referenced, param_referenced), binds? or param_binds?}
      end)

    {{name, meta, params}, referenced, binds?}
  end

  defp head(head), do: opaque(head)

  defp param({:\\, meta, [var, default]}) do
    {default, referenced, binds?} = walk(default, scope_new(), :all)
    {{:\\, meta, [var, default]}, union(referenced, referenced_names(var)), binds?}
  end

  defp param(param), do: opaque(param)

  defp head_names({:when, _meta, [call | _guards]}), do: head_names(call)

  defp head_names({_name, _meta, params}) when is_list(params),
    do: Enum.flat_map(params, &param_names/1)

  defp head_names(_head), do: []

  defp param_names({:\\, _meta, [var, _default]}), do: param_names(var)
  defp param_names(param), do: PatternStructure.bound_var_names(param)

  # --- structural forms: their clauses scope, and their heads sequence ---------------------

  defp structural({:fn, meta, clauses}, scope, later) do
    {clauses, referenced, binds?} = clauses(clauses, :pattern, scope, later)
    {{:fn, meta, clauses}, referenced, binds?}
  end

  # The subject (or condition) is evaluated first, and what it binds the clauses see.
  defp structural({form, meta, [subject, blocks]}, scope, later)
       when form in [:case, :if, :unless] and is_list(blocks) do
    {blocks, referenced, binds?} = blocks(form, blocks, bind(scope, escaping(subject)))

    {subject, subject_referenced, subject_binds?} =
      walk(subject, scope, union(later, referenced))

    binds? = subject_binds? or binds?

    {{form, stamp_if(meta, binds?, scope, later), [subject, blocks]},
     union(subject_referenced, referenced), binds?}
  end

  defp structural({form, meta, [blocks]}, scope, later)
       when form in [:cond, :receive, :try] and is_list(blocks) do
    {blocks, referenced, binds?} = blocks(form, blocks, scope)
    {{form, stamp_if(meta, binds?, scope, later), [blocks]}, referenced, binds?}
  end

  # `with`/`for`: the clauses before the blocks bind in sequence for the blocks; a `for`'s
  # options (`into:`, `reduce:`, `uniq:`) ride in the same keyword list as its blocks.
  defp structural({form, meta, [_ | _] = args}, scope, later) when form in [:with, :for] do
    case Enum.split(args, -1) do
      {clauses, [blocks]} when is_list(blocks) ->
        {clauses, inner, clauses_referenced, clauses_binds?} =
          generators(clauses, scope, blocks)

        {blocks, referenced, binds?} = blocks(form, blocks, inner, scope)
        binds? = clauses_binds? or binds?

        {{form, stamp_if(meta, binds?, scope, later), clauses ++ [blocks]},
         union(clauses_referenced, referenced), binds?}

      _other ->
        call({form, meta, args}, scope, later)
    end
  end

  # A structural form in a shape this pass does not read is walked as a call.
  defp structural(node, scope, later), do: call(node, scope, later)

  # `pattern <- value` binds the pattern for what follows; any other clause is an expression
  # whose escaping bindings follow it, like a statement. Nothing outside the form reads either.
  defp generators(clauses, scope, blocks) do
    {clauses, inner, referenced, binds?} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({[], scope, MapSet.new(), false}, fn {clause, i},
                                                          {acc, scope, referenced, binds?} ->
        rest = Enum.drop(clauses, i + 1)

        {clause, clause_referenced, clause_binds?} =
          walk(clause, scope, referenced_names([rest, blocks]))

        {[clause | acc], bind(scope, generator_names(clause)),
         union(referenced, clause_referenced), binds? or clause_binds?}
      end)

    {Enum.reverse(clauses), inner, referenced, binds?}
  end

  defp generator_names({:<-, _meta, [{:when, _when_meta, [pattern | _guards]}, _value]}),
    do: PatternStructure.bound_var_names(pattern)

  defp generator_names({:<-, _meta, [pattern, _value]}),
    do: PatternStructure.bound_var_names(pattern)

  defp generator_names(clause), do: escaping(clause)

  # The keyword blocks of a structural form (or of a definition, read as a `try`'s). A `->`
  # clause list is scoped per clause; a plain block is a statement sequence. An `else:` sees
  # `outer` — a `with`'s `else` never sees its clauses' bindings. What a block binds never
  # leaves the form, so nothing is read after it.
  defp blocks(form, blocks, scope, outer \\ nil) do
    outer = outer || scope

    blocks
    |> Enum.reverse()
    |> Enum.reduce({[], MapSet.new(), false}, fn
      {key, value}, {acc, referenced, binds?} ->
        name = AST.key_atom(key)
        block_scope = if name == :else, do: outer, else: scope
        {value, value_referenced, value_binds?} = block(form, name, value, block_scope)
        {[{key, value} | acc], union(referenced, value_referenced), binds? or value_binds?}

      other, {acc, referenced, binds?} ->
        {other, other_referenced, other_binds?} = opaque(other)
        {[other | acc], union(referenced, other_referenced), binds? or other_binds?}
    end)
  end

  defp block(form, key, [{:->, _, _} | _] = clauses, scope),
    do: clauses(clauses, heads_kind(form, key), scope, MapSet.new())

  defp block(_form, _key, value, scope), do: scoped(value, scope, MapSet.new())

  # A `cond` clause and a `receive`'s `after` are headed by an expression; every other clause
  # by patterns.
  defp heads_kind(:cond, _key), do: :expression
  defp heads_kind(:receive, :after), do: :expression
  defp heads_kind(_form, _key), do: :pattern

  defp clauses(clauses, kind, scope, later) do
    clauses
    |> Enum.reverse()
    |> Enum.reduce({[], MapSet.new(), false}, fn clause, {acc, referenced, binds?} ->
      {clause, clause_referenced, clause_binds?} = clause(clause, kind, scope, later)
      {[clause | acc], union(referenced, clause_referenced), binds? or clause_binds?}
    end)
  end

  # A clause's body sees its patterns, or what its head expression binds; what it binds is
  # read by nothing after it. (A bare `->`, outside any form this pass reads, keeps `later`.)
  defp clause({:->, meta, [heads, body]}, kind, scope, later) do
    body_later = if kind == :bare, do: later, else: MapSet.new()

    {body, referenced, binds?} =
      scoped(body, bind(scope, clause_names(heads, kind)), body_later)

    {heads, heads_referenced, heads_binds?} =
      clause_heads(heads, kind, scope, union(later, referenced))

    {{:->, meta, [heads, body]}, union(heads_referenced, referenced), heads_binds? or binds?}
  end

  defp clause(other, _kind, scope, later), do: walk(other, scope, later)

  defp clause_names([head], :expression), do: escaping(head)
  defp clause_names(heads, _kind), do: Enum.flat_map(heads, &pattern_names/1)

  defp clause_heads([head], :expression, scope, later) do
    {head, referenced, binds?} = walk(head, scope, later)
    {[head], referenced, binds?}
  end

  defp clause_heads(heads, _kind, _scope, _later),
    do: {heads, referenced_names(heads), matched_names(heads) != []}

  defp pattern_names({:when, _meta, args}) do
    {patterns, _guard} = Enum.split(args, -1)
    Enum.flat_map(patterns, &PatternStructure.bound_var_names/1)
  end

  defp pattern_names(pattern), do: PatternStructure.bound_var_names(pattern)

  # --- calls: callee and arguments are siblings --------------------------------------------

  defp call({form, meta, args}, scope, later) do
    # The callee expression runs first: its writes conflict in every argument, and everything
    # the arguments reference follows it.
    {args, referenced, binds?} =
      case Meta.routing(meta) do
        routes when is_list(routes) -> routed_arguments(args, routes, scope, later)
        _unrouted -> sequence(args, conflict(scope, possible_writes(form)), later, :siblings)
      end

    {form, form_referenced, form_binds?} = walk(form, scope, union(later, referenced))
    binds? = form_binds? or binds?

    {{form, stamp_if(meta, binds?, scope, later), args}, union(form_referenced, referenced),
     binds?}
  end

  # A route says how each position is read, and its writes are read the same way. A macro
  # places its positions as it likes, so each takes every other one's writes as conflicts.
  defp routed_arguments(args, routes, scope, later) do
    args
    |> Enum.zip(routes)
    |> positions(scope, later)
  end

  defp position(arg, treatment, scope, later) when treatment in @values,
    do: walk(arg, scope, later)

  defp position(arg, {:keyword, _} = treatment, scope, later),
    do: keyword_position(arg, treatment, scope, later)

  defp position(arg, {:keyed, _, _} = treatment, scope, later),
    do: keyword_position(arg, treatment, scope, later)

  # A declared binding position (`destructure/2`'s pattern) binds, whatever its syntax.
  defp position(arg, :binding_pattern, _scope, _later),
    do: {arg, referenced_names(arg), PatternStructure.bound_var_names(arg) != []}

  defp position(arg, _treatment, _scope, _later), do: opaque(arg)

  # The pairs of a keyword position are positions themselves: each key and value takes every
  # other one's writes as conflicts, read as their treatments say.
  defp keyword_position(arg, treatment, scope, later) do
    case KeywordRouting.decode(arg, treatment) do
      {:pairs, pairs, rewrap} ->
        parts = Enum.flat_map(pairs, fn {key, value} -> [key, value] end)
        {parts, referenced, binds?} = positions(parts, scope, later)
        pairs = parts |> Enum.chunk_every(2) |> Enum.map(fn [key, value] -> {key, value} end)
        {rewrap.(pairs), referenced, binds?}

      {:whole, fallback} ->
        position(arg, fallback, scope, later)
    end
  end

  # `{node, treatment}` positions in a macro's hands: each is walked as its treatment says,
  # with every other position's possible writes as conflicts and every other position's
  # references as later — the macro, not the written order, says which runs first.
  defp positions(positions, scope, later) do
    writes =
      Enum.map(positions, fn {node, treatment} ->
        BindingEscapeEmit.argument_bindings(node, treatment) ++ matched_names(node)
      end)

    all_referenced = referenced_names(Enum.map(positions, &elem(&1, 0)))

    positions
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce({[], MapSet.new(), false}, fn {{node, treatment}, i},
                                                 {acc, referenced, binds?} ->
      others = writes |> List.delete_at(i) |> List.flatten()

      {node, node_referenced, node_binds?} =
        position(node, treatment, conflict(scope, others), union(later, all_referenced))

      {[node | acc], union(referenced, node_referenced), binds? or node_binds?}
    end)
  end

  # --- sequences and scopes -------------------------------------------------------------------

  # A body: one statement, or a `__block__` of them, in order.
  defp scoped({:__block__, meta, statements}, scope, later) when is_list(statements) do
    {statements, referenced, binds?} = sequence(statements, scope, later, :statements)
    {{:__block__, stamp_if(meta, binds?, scope, later), statements}, referenced, binds?}
  end

  defp scoped(body, scope, later), do: walk(body, scope, later)

  # Items evaluated in order, each followed by what the ones after it reference. What the
  # ones before an item write is bound for it (`:statements`), a conflict for it
  # (`:siblings`), or nothing to it (`:unsequenced`, a module body).
  defp sequence(items, scope, later, kind) do
    entries =
      Enum.scan(items, scope, fn item, entry ->
        case kind do
          :statements -> bind(entry, escaping(item))
          :siblings -> conflict(entry, possible_writes(item))
          :unsequenced -> entry
        end
      end)

    items
    |> Enum.zip([scope | entries])
    |> Enum.reverse()
    |> Enum.reduce({[], MapSet.new(), false}, fn {item, entry}, {acc, referenced, binds?} ->
      {item, item_referenced, item_binds?} = walk(item, entry, union(later, referenced))
      {[item | acc], union(referenced, item_referenced), binds? or item_binds?}
    end)
  end

  defp escaping(node), do: BindingEscapeEmit.expression_bindings(node)

  # What `node` may write: what it is guaranteed to bind, and any match anywhere in it.
  defp possible_writes(node), do: escaping(node) ++ matched_names(node)

  defp union(:all, _names), do: :all
  defp union(_names, :all), do: :all
  defp union(left, right) when is_list(right), do: MapSet.union(left, MapSet.new(right))
  defp union(left, right), do: MapSet.union(left, right)

  defp stamp_if(meta, true, scope, later), do: stamp(meta, scope, later)
  defp stamp_if(meta, false, _scope, _later), do: meta

  defp stamp(meta, {bound, conflicts}, later),
    do: Meta.put_bindings(meta, {bound, conflicts, later})
end
